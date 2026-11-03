local assert = require "luassert"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local checker = require "titan-compiler.checker"

local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"

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
local function definition_snapshot(generated)
    local all = {}
    local texts = {
        generated.private_header or "", generated.foreign_header or "",
    }
    for _, part in ipairs(generated.parts) do texts[#texts + 1] = part.code end
    for _, text in ipairs(texts) do
        for name, definition in pairs(definitions(text)) do
            assert.is_nil(all[name], "duplicate definition " .. name)
            all[name] = definition.stamp
        end
    end
    return all
end
local function native_output(target, parts, located)
    local generated = generate(target, parts, DEFINITION_SOURCE, located)
    local texts = {
        generated.private_header or "", generated.foreign_header or "",
    }
    for _, part in ipairs(generated.parts) do texts[#texts + 1] = part.code end
    return table.concat(texts, "\0"), generated
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
        -- The complete C/private-header/foreign-header bytes stay a function of
        -- the native inputs alone: no target spelling or prior browser
        -- generation may leak state into them.
        local native = {}
        for _, parts in ipairs({ 1, 4 }) do
            for _, located in ipairs({ false, true }) do
                local key = parts .. ":" .. tostring(located)
                native[key] = assert(native_output(nil, parts, located))
                assert.equal(native[key], (native_output("linux", parts, located)))
            end
        end
        generate("browser", 4)
        for _, parts in ipairs({ 1, 4 }) do
            for _, located in ipairs({ false, true }) do
                local key = parts .. ":" .. tostring(located)
                assert.equal(native[key], (native_output("linux", parts, located)), key)
            end
        end
    end)

    it("gives native function definitions the same stamps as the browser target", function()
        for _, parts in ipairs({ 1, 4 }) do
            local native = definition_snapshot(generate(nil, parts, DEFINITION_SOURCE))
            local browser = definition_snapshot(generate("browser", parts, DEFINITION_SOURCE))
            assert.same(browser, native)
            local generated_stamps = 0
            for name, stamp in pairs(native) do
                assert.is_not_nil(stamp, name)
                if stamp == "1 TITAN_GENERATED_C_FILE" then
                    generated_stamps = generated_stamps + 1
                end
            end
            assert.is_true(generated_stamps > 10,
                "generated definitions lost their generated-C reset")
        end
    end)

    it("removes every definition stamp when line directives are disabled", function()
        for _, parts in ipairs({ 1, 4 }) do
            local text = assert(native_output(nil, parts, false))
            assert.is_nil(text:find("#line", 1, true), parts)
            assert.is_nil(text:find("TITAN_GENERATED_C_FILE", 1, true), parts)
            assert.same({}, definition_snapshot(generate(nil, parts, DEFINITION_SOURCE, false)))
        end
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

    it("stamps immediate and graph foreign-header plans identically on both targets", function()
        local native, ast = generate(nil, 1, DEFINITION_SOURCE)
        local immediate = driver.plan_foreign_header("entries", ast,
            "/generated/entries.titan", false)
        local graph = assert(driver.plan_foreign_headers({ "entries" }, {
            entries = { ast = ast, filename = "/generated/entries.titan" },
        }))
        assert.equal(immediate.contents, graph[1].contents)
        local count = 0
        for name, definition in pairs(definitions(graph[1].contents)) do
            count = count + 1
            assert.match('^%d+ "entries[.]browser[.]titan"$', definition.stamp, name)
        end
        assert.equal(3, count)
        assert.equal(native.foreign_header, immediate.contents)
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

    it("changes native foreign bodies only by line controls under the line policy", function()
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
        assert.is_nil(unlocated:find("TITAN_GENERATED_C_FILE", 1, true))
        local function without_directives(text)
            return (text:gsub("[ \t]*#line[^\n]*\n", "")
                :gsub('^#define[ \t]+TITAN_GENERATED_C_FILE[ \t]+"[^"\n]*"\n', "")
                :gsub("\n[ \t\n]*\n", "\n"))
        end
        assert.equal(without_directives(unlocated), without_directives(located))
    end)

    it("emits an empty balanced registry for a module without Lua-callable entries", function()
        local text = code(generate("browser", 1, "local state: integer = 1\n"))
        assert.same({}, entries({ parts = { { code = text } } }))
        assert.truthy(text:find("lua_pop(L, 1);", assert(text:find("TITAN_ENTRIES_KEY", 1, true)), true))
    end)
end)

-- Foreign headers are rendered before (and, for restored plans, independently
-- of) C generation, so their line/coverage policy is an explicit input of the
-- plan. These cases drive the real driver planner/renderer without generating
-- C first, which is where ambient coder state used to leak in.
describe("foreign-header emission policy", function()
    local FOREIGN = [[
local foreign function copy(n: int): int return n end
function get(): integer return 1 end
]]
    local function checked_ast()
        h.reset(true)
        local ast, err = parser.parse("entries.browser.titan", FOREIGN)
        assert.truthy(ast, err)
        local _, errors = checker.check("entries", ast, FOREIGN,
            "entries.browser.titan")
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return ast
    end
    local function planned(policy)
        return assert(driver.plan_foreign_header("entries", checked_ast(),
            "/generated/entries.titan", false, policy))
    end
    local function line_count(contents)
        return select(2, (contents or ""):gsub("#line", ""))
    end
    local function stamps(contents)
        local result = {}
        for name, definition in pairs(definitions(contents or "")) do
            result[name] = definition.stamp
        end
        return result
    end
    local function stamped_header(policy)
        local plan = planned(policy)
        local result = stamps(plan.contents)
        assert.is_true(next(result) ~= nil, "fixture has no foreign definition")
        for name in pairs(result) do
            assert.is_not_nil(result[name], name)
        end
        return plan
    end

    it("plans each header under its own policy, before any C generation", function()
        assert.same({ line_directives = true, coverage = false },
            driver.header_policy(false))
        assert.equal(2, line_count(stamped_header(
            driver.header_policy(false)).contents))
        local previous = driver.EMIT_LINE_DIRECTIVES
        local tested, test_error = xpcall(function()
            -- A fresh no-line invocation: the option alone decides the header.
            driver.EMIT_LINE_DIRECTIVES = false
            assert.same({ line_directives = false, coverage = false },
                driver.header_policy(false))
            local disabled = planned(driver.header_policy(false))
            assert.equal(0, line_count(disabled.contents))
            assert.same({}, stamps(disabled.contents))
            -- C generation under the same policy accepts that plan and emits
            -- no stamps of its own.
            local generated = coder.generate("entries", checked_ast(), {},
                driver.TITAN_ABI_VERSION, false, {
                    source_output_stem = "/generated/entries",
                    foreign_header_plan = disabled,
                })
            assert.is_nil(code(generated):find("#line", 1, true))
            -- Turning the option back on needs no intervening generation: the
            -- next header carries its own explicit enabled policy, and the
            -- disabled one keeps its bytes.
            driver.EMIT_LINE_DIRECTIVES = true
            assert.equal(2, line_count(stamped_header(
                driver.header_policy(false)).contents))
            assert.equal(0, line_count(planned(
                coder.emission_policy(false, false)).contents))
        end, debug.traceback)
        driver.EMIT_LINE_DIRECTIVES = previous
        assert.is_true(tested, test_error)
    end)

    it("rejects a header plan rendered under another emission policy", function()
        local disabled = planned(coder.emission_policy(false, false))
        assert.equal(0, line_count(disabled.contents))
        local ok, err = pcall(coder.generate, "entries", checked_ast(), {},
            driver.TITAN_ABI_VERSION, true, {
                source_output_stem = "/generated/entries",
                foreign_header_plan = disabled,
            })
        assert.is_false(ok)
        assert.truthy(tostring(err):find("different emission policy", 1, true),
            tostring(err))
    end)

    for _, backend in ipairs({ "gcc-gcov", "llvm-gcov" }) do
        it("renders a selected coverage relay with the coverage policy under "
            .. backend, function()
            local ast = checked_ast()
            coder.prepare_coverage(ast, true)
            local covered = assert(driver.plan_foreign_header("entries", ast,
                "/generated/entries.titan", false, driver.header_policy(true)))
            assert.equal(0, line_count(covered.contents))
            assert.same({}, stamps(covered.contents))
            local generated = coder.generate("entries", ast, {},
                driver.TITAN_ABI_VERSION, true, {
                    coverage = true,
                    coverage_backend = backend,
                    source_output_stem = "/generated/entries",
                    foreign_header_plan = covered,
                })
            local text = code(generated)
            assert.is_nil(text:find("#line ", 1, true))
            assert.truthy(text:find("TITAN_COVERAGE_BEGIN", 1, true))
            -- Coverage must not leave the coder suppressing later plans.
            assert.equal(2, line_count(stamped_header(
                driver.header_policy(false)).contents))
        end)
    end

    it("applies per-module policies to one graph header plan", function()
        local plain = checked_ast()
        local covered = checked_ast()
        coder.prepare_coverage(covered, true)
        local plans = assert(driver.plan_foreign_headers({ "plain", "covered" }, {
            plain = { ast = plain, filename = "/generated/plain.titan" },
            covered = { ast = covered, filename = "/generated/covered.titan" },
        }, function(name)
            return driver.header_policy(name == "covered")
        end))
        local by_name = {}
        for _, plan in ipairs(plans) do by_name[plan.modname] = plan end
        assert.equal(2, line_count(by_name.plain.contents))
        assert.is_true(next(stamps(by_name.plain.contents)) ~= nil)
        assert.equal(0, line_count(by_name.covered.contents))
        assert.same({}, stamps(by_name.covered.contents))
        assert.same(driver.header_policy(false), by_name.plain.policy)
        assert.same(driver.header_policy(true), by_name.covered.policy)
    end)
end)

-- A published foreign-header plan is one immutable unit: policy, the identity
-- of the source it was rendered from, contents and the digest of the recipe
-- that produced them. A build under another policy, or over changed source,
-- must republish the header (disk, recipe and C agreeing), in the same process
-- and across processes.
describe("published foreign-header plans", function()
    local MODULE = "policy"
    local FOREIGN = [[
local foreign function copy(n: int): int return n end
function get(): integer return copy(1) end
]]
    local COVERAGE_FLAGS = { "-O0", "-fno-lto", "--coverage",
        "-fprofile-update=atomic" }

    local function write_source(dir, source)
        local path = dir .. "/" .. MODULE .. ".titan"
        local file = assert(io.open(path, "wb"))
        assert(file:write(source))
        assert(file:close())
        return path
    end
    local function checked_ast(source, path)
        h.reset(true)
        local ast, err = parser.parse(path, source)
        assert.truthy(ast, err)
        local _, errors = checker.check(MODULE, ast, source, path)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return ast
    end
    local function read(path)
        local file = assert(io.open(path, "rb"))
        local contents = file:read("*a")
        file:close()
        return contents
    end
    local function line_count(contents)
        return select(2, (contents or ""):gsub("#line", ""))
    end
    local function build(dir, emit, coverage, entry, source)
        local previous = driver.EMIT_LINE_DIRECTIVES
        driver.EMIT_LINE_DIRECTIVES = emit
        local path = write_source(dir, source or FOREIGN)
        local ast = checked_ast(source or FOREIGN, path)
        local captured
        local original = driver.plan_foreign_header
        driver.plan_foreign_header = function(...)
            local plan = original(...)
            captured = plan
            return plan
        end
        local ok, compiled, original_err = pcall(function()
            local options = {}
            if coverage then
                options.coverage = true
                options.coverage_backend = "gcc-gcov"
                options.extra_compile_flags = COVERAGE_FLAGS
            end
            return driver.compile(MODULE, ast, path, {}, false, options, entry)
        end)
        driver.plan_foreign_header = original
        driver.EMIT_LINE_DIRECTIVES = previous
        assert.is_true(ok, compiled)
        assert.truthy(compiled, original_err)
        local plan = assert(captured, "compile did not plan the foreign header")
        return {
            plan = plan,
            header = read(dir .. "/" .. MODULE .. ".titan.h"),
            c = read(dir .. "/" .. MODULE .. ".c"),
        }
    end
    local function temporary_directory()
        local path = assert(compiler_io.new_sync():tmpname())
        os.remove(path)
        assert(lfs.mkdir(path))
        return path
    end
    local function remove_directory(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                os.remove(path .. "/" .. entry)
            end
        end
        assert(lfs.rmdir(path))
    end
    local function assert_policy(built, emit, coverage)
        assert.same({ line_directives = emit, coverage = coverage },
            built.plan.recipe.policy)
        assert.equal(coder.foreign_header_digest(built.plan.recipe),
            built.plan.digest)
        local expected = emit and not coverage and 2 or 0
        assert.equal(expected, line_count(built.header))
        if coverage then
            -- Converted coverage C opens with a generated-file anchor and
            -- still names the Titan source; the header carries no stamps.
            assert.truthy(built.c:match('^#line %d+ "[^"\n]*policy[.]c"'),
                "coverage C is not the converted form")
            assert.truthy(built.c:find(MODULE .. ".titan", 1, true))
        elseif emit then
            assert.truthy(built.c:find("#define TITAN_GENERATED_C_FILE",
                1, true))
            assert.is_true(line_count(built.c) > 0)
        else
            assert.equal(0, line_count(built.c))
            assert.is_nil(built.c:find("TITAN_GENERATED_C_FILE", 1, true))
        end
    end

    it("republishes the header when the line-directive policy changes in one process", function()
        local dir = temporary_directory()
        local tested, test_error = xpcall(function()
            -- One resolver entry reuses the module's published plan between
            -- builds, so the policy check is exercised, not bypassed.
            local entry = { kind = "source", filename = dir .. "/policy.titan",
                source_files = { dir .. "/policy.titan" }, deps = {} }
            local disabled = build(dir, false, false, entry)
            assert_policy(disabled, false, false)
            assert.equal(disabled.plan, entry.foreign_header_plan)
            local enabled = build(dir, true, false, entry)
            assert_policy(enabled, true, false)
            assert.not_equal(disabled.plan.digest, enabled.plan.digest)
            assert.equal(enabled.plan, entry.foreign_header_plan)
            local again = build(dir, false, false, entry)
            assert_policy(again, false, false)
            assert.equal(disabled.plan.digest, again.plan.digest)
        end, debug.traceback)
        remove_directory(dir)
        assert.is_true(tested, test_error)
    end)

    it("republishes the header when the coverage selection changes in one process", function()
        local dir = temporary_directory()
        local tested, test_error = xpcall(function()
            local entry = { kind = "source", filename = dir .. "/policy.titan",
                source_files = { dir .. "/policy.titan" }, deps = {} }
            local covered = build(dir, true, true, entry)
            assert_policy(covered, true, true)
            local plain = build(dir, true, false, entry)
            assert_policy(plain, true, false)
            assert.not_equal(covered.plan.digest, plain.plan.digest)
            assert.equal(plain.plan, entry.foreign_header_plan)
            assert_policy(build(dir, true, true, entry), true, true)
        end, debug.traceback)
        remove_directory(dir)
        assert.is_true(tested, test_error)
    end)

    it("republishes the header across processes under the current policy", function()
        local dir = temporary_directory()
        local script = dir .. "/build.lua"
        local file = assert(io.open(script, "wb"))
        assert(file:write(([[
package.path = "./?.lua;./?/init.lua;" .. package.path
local h = require "spec.support.helpers"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local checker = require "titan-compiler.checker"
local SOURCE = ]] .. string.format("%q", FOREIGN) .. [[
h.reset(true)
driver.EMIT_LINE_DIRECTIVES = arg[2] == "on"
local ast = assert(parser.parse("policy.titan", SOURCE))
local _, errors = checker.check("policy", ast, SOURCE, "policy.titan")
assert(0 == #errors, table.concat(errors, "\n"))
local ok, err = driver.compile("policy", ast, arg[1] .. "/policy.titan", {}, false, {})
assert(ok, err)
]])))
        assert(file:close())
        local LUA = require("spec.support.installed_prefix").active()
            .. (require("titan-compiler.platform").windows and "/bin/lua.exe" or "/bin/lua")
        local function child(emit)
            local result = compiler_io.new_sync():run({
                LUA, script, dir, emit and "on" or "off" })
            assert.truthy(result.ok, result.output or result.diagnostic)
            return read(dir .. "/policy.titan.h")
        end
        local tested, test_error = xpcall(function()
            -- A fresh process publishes under the disabled policy; this process
            -- then rebuilds under the enabled one.
            assert.equal(0, line_count(child(false)))
            local enabled = build(dir, true, false)
            assert_policy(enabled, true, false)
            -- A second fresh process rebuilds under the disabled policy again.
            assert.equal(0, line_count(child(false)))
            local disabled = build(dir, false, false)
            assert_policy(disabled, false, false)
        end, debug.traceback)
        os.remove(script)
        remove_directory(dir)
        assert.is_true(tested, test_error)
    end)

    it("republishes when the foreign source changes under the same policy", function()
        local dir = temporary_directory()
        local tested, test_error = xpcall(function()
            local entry = { kind = "source", filename = dir .. "/policy.titan",
                source_files = { dir .. "/policy.titan" }, deps = {} }
            local function body(value)
                return (FOREIGN:gsub("return n end",
                    "return n + " .. value .. " end"))
            end
            local first = build(dir, true, false, entry, body(1234))
            assert.truthy(first.header:find("1234", 1, true))
            assert.equal(first.plan, entry.foreign_header_plan)
            assert.is_not_nil(first.plan.source)
            -- Same entry, same policy, changed body: the published header must
            -- follow the new source instead of reusing the old plan.
            local second = build(dir, true, false, entry, body(5678))
            assert.truthy(second.header:find("5678", 1, true))
            assert.is_nil(second.header:find("1234", 1, true))
            assert.not_equal(first.plan.source, second.plan.source)
            assert.not_equal(first.plan.digest, second.plan.digest)
            assert.equal(second.plan, entry.foreign_header_plan)
            -- A changed foreign signature is a source change too.
            local signature = (FOREIGN:gsub(
                "copy%(n: int%): int return n end",
                "copy(n: int, m: int): int return n + m end")
                :gsub("copy%(1%)", "copy(1, 2)"))
            local third = build(dir, true, false, entry, signature)
            assert.truthy(third.header:find(
                [[\u2119_foreign_inline_copy(int _param_n, int _param_m)]],
                1, true), third.header)
            assert.is_nil(third.header:find("5678", 1, true))
            assert.not_equal(second.plan.source, third.plan.source)
            assert.equal(third.plan, entry.foreign_header_plan)
        end, debug.traceback)
        remove_directory(dir)
        assert.is_true(tested, test_error)
    end)

    it("makes the emission policy part of the header recipe identity", function()
        local prefix, body = "prefix", "body"
        local headers = { "dependency" }
        local function recipe(emit, coverage)
            return { prefix = prefix, body = body, source_headers = headers,
                policy = { line_directives = emit, coverage = coverage } }
        end
        local function digest(emit, coverage)
            return coder.foreign_header_digest(recipe(emit, coverage))
        end
        -- Identical rendered text with a different policy is a different unit.
        assert.equal(digest(true, false), digest(true, false))
        assert.not_equal(digest(true, false), digest(false, false))
        assert.not_equal(digest(true, false), digest(true, true))
        assert.not_equal(digest(true, false), coder.foreign_header_digest(
            { prefix = prefix, body = body, source_headers = headers }))
    end)
end)


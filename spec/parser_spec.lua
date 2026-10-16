local parser = require 'titan-compiler.parser'
local location = require 'titan-compiler.location'
local syntax_errors = require 'titan-compiler.syntax_errors'
local util = require 'titan-compiler.util'

--
-- Our syntax trees contain a lot of extra information in them such as token
-- positions, type annotations and so on. To avoid having the tests break all
-- the time when these change, we only check if the subset of the tree that we
-- are interested in is present instead of
--

-- Return a version of t2 that only contains fields present in t1 (recursively)
-- Example:
--   t1  = { b = { c = 10 } e = 40 }
--   t2  = { a = 1, b = { c = 20, d = 30} }
--   out = { b = { c = 20 } }
local function restrict(t1, t2)
    if type(t1) == 'table' and type(t2) == 'table' then
        local out = {}
        for k,_ in pairs(t1) do
            out[k] = restrict(t1[k], t2[k])
        end
        return out
    else
        return t2
    end
end

local function candidate_expectations(node)
    if type(node) ~= "table" then return end
    if node.vars then
        for i, var in ipairs(node.vars) do
            if var._tag ~= "Ast.ExpVar" then
                node.vars[i] = { _tag = "Ast.ExpVar", var = var }
            end
        end
    end
    for _, child in pairs(node) do candidate_expectations(child) end
end

local function assert_is_subset(expected_ast, ast)
    candidate_expectations(expected_ast)
    assert.are.same(expected_ast, restrict(expected_ast, ast))
end

--
-- Assertions for full programs
--

local function assert_parses_successfuly(program_str)
    local ast, err = parser.parse("(parser_spec)", program_str)
    if not ast then
        error(string.format("Unexpected Titan syntax error: %s", err and err.label or "?"))
    end
    return ast
end


local function assert_program_ast(program_str, expected_ast)
    local ast = assert_parses_successfuly(program_str)
    assert_is_subset(expected_ast, ast)
end

local function assert_program_syntax_error(program_str, expected_error_label)
    local ast, err = parser.parse("(parser_spec)", program_str)
    if ast then
        error(string.format("Expected Titan syntax error %s but parsed successfuly", expected_error_label))
    end
    assert.are.same(expected_error_label, err and err.label)
end


--
-- Assertions for types
--

local function type_test_program(s)
    return util.render([[
        local x: $TYPE = nil
    ]], { TYPE = s } )
end

local function assert_type_ast(code, expected_ast)
    local program_str = type_test_program(code)
    local program_ast = assert_parses_successfuly(program_str)
    local ast = program_ast[1].decl.type
    assert_is_subset(expected_ast, ast)
end

local function assert_type_syntax_error(code, expected_error_label)
    local program_str = type_test_program(code)
    assert_program_syntax_error(program_str, expected_error_label)
end

--
-- Assertions for expressions
--

local function expression_test_program(s)
    return util.render([[
        function foo(): nil
            x = $EXPR
        end
    ]], { EXPR = s })
end

local function assert_expression_ast(code, expected_ast)
    local program_str = expression_test_program(code)
    local program_ast = assert_parses_successfuly(program_str)
    local ast = program_ast[1].block.stats[1].exps[1]
    assert_is_subset(expected_ast, ast)
    return ast
end

local function assert_expression_syntax_error(code, expected_error_label)
    local program_str = expression_test_program(code)
    assert_program_syntax_error(program_str, expected_error_label)
end

--
-- Assertions for statements
--

local function statements_test_program(s)
    return util.render([[
        function foo(): nil
            $STATS
        end
    ]], { STATS = s })
end

local function assert_statements_ast(code, expected_ast)
    local program_str = statements_test_program(code)
    local program_ast = assert_parses_successfuly(program_str)
    local ast = program_ast[1].block.stats
    assert_is_subset(expected_ast, ast)
end

local function assert_statements_syntax_error(code, expected_error_label)
    local program_str = statements_test_program(code)
    assert_program_syntax_error(program_str, expected_error_label)
end

-- Keep this independent of wall-clock timing. The hook counts Lua VM
-- instructions only while parser.parse is running and always restores any
-- hook installed by the test runner, including when the parser raises.
local function parse_under_instruction_budget(program_str, budget, error_label)
    local previous_hook, previous_mask, previous_count = debug.gethook()
    local quantum = 100
    local instructions = 0

    debug.sethook(function()
        instructions = instructions + quantum
        if instructions > budget then
            -- Disable this hook before raising so the handful of Lua
            -- instructions between pcall returning and restoration cannot
            -- trigger a second, uncaught budget error.
            debug.sethook()
            error("parser instruction budget exceeded", 0)
        end
    end, "", quantum)

    local ok, ast, err = pcall(
        parser.parse, "(parser_instruction_budget)", program_str)
    debug.sethook(previous_hook, previous_mask, previous_count)

    assert.is_true(ok, tostring(ast))
    if error_label then
        assert.falsy(ast)
        assert.are.equal(error_label, err and err.label)
    else
        assert.truthy(ast, err and err.label or "parser returned no AST")
    end
    return ast, instructions
end

--
--
--

describe("Titan parser", function()
    local ORIGINAL_FORMAT_LEVEL

    setup(function()
        -- Print the whole AST when it doesn't match, instead of just a handful
        -- of nodes. A depth of 100 should be more than enough. Although the
        -- luassert docs suggest -1 to show an infinite number of levels, that
        -- can get stuck in an infinite loop if we have self-referential tables.
        ORIGINAL_FORMAT_LEVEL = assert:get_parameter("TableFormatLevel")
        assert:set_parameter("TableFormatLevel", 100)
    end)

    teardown(function()
        assert:set_parameter("TableFormatLevel", ORIGINAL_FORMAT_LEVEL)
    end)

    assert:set_parameter("TableFormatLevel", -1)

    it("uses nil for absent syntax without losing false values or list positions", function()
        local tree = assert_parses_successfuly([[
            local enabled = false
            local pending: integer?
            function f<|T|>(first: integer, ...: string)
                local inferred = 1
                for i = 1, 2 do end
                if enabled then end
                local values = {false, 2}
            end
            local implicit = function(x, ...) end
            local explicit = function(): () end
        ]])
        assert.is_nil(tree[1].decl.type)
        assert.is_false(tree[1].value.value)
        assert.is_nil(tree[2].value)
        local declaration = tree[3]
        assert.is_nil(declaration.typeparams[1].constraint)
        assert.equal(2, #declaration.params)
        assert.equal("first", declaration.params[1].name)
        assert.is_nil(declaration.params[2].name)
        assert.equal("Ast.TypeString", declaration.params[2].type._tag)
        assert.is_nil(declaration.flexrettype)
        local stats = declaration.block.stats
        assert.is_nil(stats[1].decls[1].type)
        assert.is_nil(stats[2].inc)
        assert.is_nil(stats[3].elsestat)
        assert.equal(2, #stats[4].exps[1].fields)
        assert.is_nil(stats[4].exps[1].fields[1].name)
        assert.is_false(stats[4].exps[1].fields[1].exp.value)
        local implicit, explicit = tree[4].value, tree[5].value
        assert.equal(2, #implicit.params)
        assert.is_nil(implicit.params[2].name)
        assert.is_nil(implicit.params[2].type)
        assert.is_nil(implicit.rettypes)
        assert.is_nil(implicit.flexrettype)
        assert.same({}, explicit.rettypes)
        assert.is_nil(explicit.flexrettype)
    end)

    it("initializes computed plans independently as unknown", function()
        local tree = assert_parses_successfuly([[
            local count = 0
            function f(x: value): boolean
                local cast = x as integer
                local predicate = x is integer
                return cast == 1
            end
        ]])
        assert.same({tag="unknown"}, tree[1]._lua_write_dynamic_plan)
        local declaration = tree[2]
        assert.same({tag="unknown"}, declaration._lua_vararg_dynamic_plan)
        assert.same({tag="unknown"}, declaration._strict_vararg_guard_plan)
        assert.same({tag="unknown"}, declaration.params[1]._dynamic_plan)
        local stats = declaration.block.stats
        assert.same({tag="unknown"}, stats[1].exps[1]._written_cast)
        assert.same({tag="unknown"}, stats[2].exps[1]._written_cast)
        assert.same({tag="unknown"}, stats[3].exps[1]._comparison)
        assert.is_false(rawequal(stats[1].exps[1]._written_cast,
            stats[2].exps[1]._written_cast))
    end)

    it("can parse programs starting with whitespace or comments", function()
        -- (This is easy to get wrong in hand-written LPeg grammars)
        local ast = assert_parses_successfuly("--hello\n--bla\n  ")
        assert.are.same({}, ast)
    end)

    it("incrementally consumes large top-level declaration lists", function()
        local source = { "local first = 1" }
        local records = 180
        for i = 1, records do
            source[#source + 1] = string.format("local record R%d end", i)
        end
        source[#source + 1] = "local last = 2"
        source[#source + 1] = "do return end"

        local ast = assert_parses_successfuly(table.concat(source, "\n"))
        -- Each record contributes the declaration followed by its synthesized
        -- local constructor; the surrounding variables and initializer retain
        -- their source order.
        assert.are.equal(2 * records + 3, #ast)
        assert.are.equal("first", ast[1].decl.name)
        assert.are.equal("Ast.TopLevelRecord", ast[2]._tag)
        assert.are.equal("R1", ast[2].name)
        assert.are.equal("Ast.TopLevelStatic", ast[3]._tag)
        assert.are.equal("new", ast[3].name)
        assert.is_true(ast[3]._record_constructor)
        assert.are.equal("last", ast[#ast - 1].decl.name)
        assert.are.equal("Ast.StatBlock", ast[#ast]._tag)
    end)

    it("preserves mixed top-level ordering while consuming incrementally",
    function()
        local source = {}
        local groups = 40
        for i = 1, groups do
            source[#source + 1] = string.format(
                'local m%d = import "module.%d"', i, i)
            source[#source + 1] = string.format(
                'foreign import "header%d.h"', i)
            source[#source + 1] = string.format(
                "record R%d item: integer end", i)
            source[#source + 1] = string.format(
                "function R%d:method(): integer return %d end", i, i)
            source[#source + 1] = string.format(
                "function R%d.static(): integer return %d end", i, i)
            source[#source + 1] = string.format(
                "local function f%d(): integer return %d end", i, i)
            source[#source + 1] = string.format("local v%d = %d", i, i)
        end

        local ast = assert_parses_successfuly(table.concat(source, "\n"))
        assert.are.equal(groups * 8, #ast)
        for i = 1, groups do
            local base = (i - 1) * 8
            assert.are.equal("Ast.TopLevelImport", ast[base + 1]._tag)
            assert.are.equal("Ast.TopLevelForeignImport", ast[base + 2]._tag)
            assert.are.equal("Ast.TopLevelRecord", ast[base + 3]._tag)
            assert.are.equal("R" .. i, ast[base + 3].name)
            assert.are.equal("Ast.TopLevelStatic", ast[base + 4]._tag)
            assert.are.equal("new", ast[base + 4].name)
            assert.are.equal("Ast.TopLevelMethod", ast[base + 5]._tag)
            assert.are.equal("Ast.TopLevelStatic", ast[base + 6]._tag)
            assert.are.equal("Ast.TopLevelFunc", ast[base + 7]._tag)
            assert.are.equal("Ast.TopLevelVar", ast[base + 8]._tag)
        end
    end)

    it("clears incremental state after a large syntax failure", function()
        local source = {}
        for i = 1, 180 do
            source[#source + 1] = string.format("local value%d = %d", i, i)
        end
        source[#source + 1] = "function broken("
        local ast, err = parser.parse("(large-malformed)",
            table.concat(source, "\n"))
        assert.falsy(ast)
        assert.truthy(err)

        local clean = assert(parser.parse("(after-large-malformed)",
            "local clean = 1"))
        assert.are.equal(1, #clean)
        assert.are.equal("clean", clean[1].decl.name)
        assert.are.equal("(after-large-malformed)", clean[1].loc.filename)
    end)

    it("can parse a module initializer block", function()
        assert_program_ast([[
            local x = 1
            do
                local y = x
                return
            end
        ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = true,
                decl = { name = "x", type = nil, option = false } },
            { _tag = "Ast.StatBlock",
                stats = {
                    { _tag = "Ast.StatDecl",
                        decls = { { name = "y", type = nil, option = false } } },
                    { _tag = "Ast.StatReturn", exps = {} },
                } },
        })

        local positioned = assert(parser.parse("initializer.titan",
            "local x = 1\n\ndo\n    x = 2\nend\n"))
        assert.same({
            filename = "initializer.titan",
            line = 3,
            col = 1,
        }, positioned[#positioned].loc)
        assert.is_true(positioned[#positioned]._module_initializer)

        local protected = assert(parser.parse("protected-initializer.titan", [[
do
    defer local cleaned: boolean = true
    raise "expected"
catch
    local caught: value = error
end
]]))
        assert.equal("Ast.StatTry", protected[#protected]._tag)
        assert.is_true(protected[#protected]._module_initializer)
        assert.same({
            filename = "protected-initializer.titan",
            line = 1,
            col = 1,
        }, protected[#protected].loc)

        assert_program_syntax_error([[
            do
                local unfinished = 1
        ]], "EndBlock")
    end)

    it("retains exact semantic identifier locations", function()
        local function assert_location(loc, line, col)
            assert.same({
                filename = "metadata.titan",
                line = line,
                col = col,
            }, loc)
        end

        local program = assert(parser.parse("metadata.titan", [[
local dep = import "pkg.dep"
local type Alias = dep.Item
record Box<|T|>
    const item: dep.Item<|T|>
end
function Box:take<|U|>(input: dep.Item<|U|>): dep.Item<|U|>
    local selected = input.item
    local bound = input:convert
    input:convert()
    input:convert{item = input}
    return input
end
]]))

        assert_location(program[1]._name_loc, 1, 7)
        assert_location(program[2]._name_loc, 2, 12)
        assert_location(program[2].type._module_loc, 2, 20)
        assert_location(program[2].type._name_loc, 2, 24)

        local record = program[3]
        assert_location(record._name_loc, 3, 8)
        assert_location(record.typeparams[1]._name_loc, 3, 13)
        assert_location(record.fields[1]._name_loc, 4, 11)
        assert_location(record.fields[1].type._module_loc, 4, 17)
        assert_location(record.fields[1].type._name_loc, 4, 21)
        assert_location(record.fields[1].type.typeargs[1]._name_loc, 4, 27)

        -- The parser inserts Box.new immediately after the record.
        local method = program[5]
        assert_location(method._owner_loc, 6, 10)
        assert_location(method._name_loc, 6, 14)
        assert_location(method.typeparams[1]._name_loc, 6, 20)
        assert_location(method.params[1]._name_loc, 6, 24)
        assert_location(method.params[1].type._module_loc, 6, 31)
        assert_location(method.params[1].type._name_loc, 6, 35)
        assert_location(method.rettypes[1]._module_loc, 6, 47)
        assert_location(method.rettypes[1]._name_loc, 6, 51)
        assert_location(method.block.stats[1].exps[1].var._name_loc, 7, 28)
        assert_location(method.block.stats[2].exps[1]._name_loc, 8, 25)
        assert_location(method.block.stats[3].callexp.args._name_loc, 9, 11)
        local named = method.block.stats[4].callexp.args
        assert_location(named._name_loc, 10, 11)
        assert_location(named.fields[1]._name_loc, 10, 19)

        local owners = assert(parser.parse("metadata.titan", [[
interface View
    item: integer
    function show()
end
union Choice
    local Some(integer)
    None()
end
]]))
        assert_location(owners[1]._name_loc, 1, 11)
        assert_location(owners[1].fields[1]._name_loc, 2, 5)
        assert_location(owners[1].methods[1]._name_loc, 3, 14)
        assert_location(owners[2]._name_loc, 5, 7)
        assert_location(owners[2].variants[1]._name_loc, 6, 11)
        assert_location(owners[2].variants[2]._name_loc, 7, 5)
    end)

    it("retains structural closing-keyword locations", function()
        local function assert_location(loc, line, col)
            assert.same({
                filename = "fold.titan",
                line = line,
                col = col,
            }, loc)
        end

        local program = assert(parser.parse("fold.titan", [[
function fold()
    if true then
    end
    while true do
    end
    repeat
    until true
    for i = 1, 2 do
    end
    for item in items do
    end
    do
    end
    case item
    when Some() then
    else
    end
    local callback = function()
    end
end
do
end
]]))

        local func = program[1]
        local stats = func.block.stats
        assert_location(func._end_loc, 20, 1)
        assert_location(stats[1]._end_loc, 3, 5)
        assert_location(stats[2]._end_loc, 5, 5)
        assert_location(stats[3]._end_loc, 7, 5)
        assert_location(stats[4]._end_loc, 9, 5)
        assert_location(stats[5]._end_loc, 11, 5)
        assert_location(stats[6]._structure_loc, 12, 5)
        assert_location(stats[6]._end_loc, 13, 5)
        assert_location(stats[7].arms[1]._name_loc, 15, 10)
        assert_location(stats[7]._end_loc, 17, 5)
        assert_location(stats[8].exps[1]._end_loc, 19, 5)
        assert.is_nil(func.block._end_loc)
        assert.is_nil(stats[1].thens[1].block._end_loc)

        local initializer = program[2]
        assert.is_true(initializer._module_initializer)
        assert_location(initializer.loc, 21, 1)
        assert_location(initializer._end_loc, 22, 1)
        assert.is_nil(initializer._structure_loc)
    end)

    it('can parse toplevel var declarations', function()

        local program = assert_parses_successfuly([[
            local x = 17
            y = 18
            local maybe: integer? = 17
            const later: string?
            local const hidden: value
        ]])
        assert_is_subset({
            {islocal=true, decl={name="x",type=nil,option=false}},
            {islocal=false, decl={name="y",type=nil}},
            {decl={name="maybe",type={_tag="Ast.TypeOption"}}},
            {isconst=true,value=nil,decl={name="later"}},
            {islocal=true,isconst=true,value=nil,decl={name="hidden"}},
        }, program)
        for _,source in ipairs({"x", "local x", "const x", "local x? = 1"}) do
            assert.falsy(parser.parse("invalid.titan",source))
        end
    end)

    it("parses initialized and initializer-less const module variables",
    function()
        local program = assert_parses_successfuly([[
            const answer: integer = 42
            local const cache: string?
            const inferred = answer
        ]])

        assert_is_subset({
            {
                _tag = "Ast.TopLevelVar",
                islocal = false,
                isconst = true,
                decl = {
                    name = "answer",
                    isconst = true,
                    type = { _tag = "Ast.TypeInteger" },
                },
                value = { _tag = "Ast.ExpInteger", value = 42 },
            },
            {
                _tag = "Ast.TopLevelVar",
                islocal = true,
                isconst = true,
                decl = {
                    name = "cache",
                    isconst = true,
                    type = { _tag = "Ast.TypeOption" },
                },
                value = nil,
            },
            {
                _tag = "Ast.TopLevelVar",
                islocal = false,
                isconst = true,
                decl = { name = "inferred", isconst = true, type = nil },
                value = { _tag = "Ast.ExpVar" },
            },
        }, program)
    end)

    it("can parse local var declarations", function()
        assert_statements_ast([[ local x=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = nil, option = false } } }
        })

        assert_statements_ast([[ local x?=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = nil, option = true } } }
        })

        assert_statements_ast([[ local x: integer=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = { _tag = "Ast.TypeInteger" }, option = false } } }
        })

        assert_statements_ast([[ local x: integer?=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = { _tag = "Ast.TypeOption", basetype = {_tag = "Ast.TypeInteger"} }, option = false } } }
        })

        assert_statements_ast([[ local pending: integer? ]], {
            { _tag = "Ast.StatDecl",
                decls = { {
                    name = "pending",
                    isconst = false,
                    type = { _tag = "Ast.TypeOption" },
                } },
                exps = {}, }
        })
    end)

    it("parses const local declarations with and without local", function()
        assert_statements_ast([[
            const x, y: integer = first, second
            local const z: string = "ready"
        ]], {
            {
                _tag = "Ast.StatDecl",
                decls = {
                    { name = "x", isconst = true, type = nil },
                    { name = "y", isconst = true,
                        type = { _tag = "Ast.TypeInteger" } },
                },
                exps = {
                    { _tag = "Ast.ExpVar" },
                    { _tag = "Ast.ExpVar" },
                },
            },
            {
                _tag = "Ast.StatDecl",
                decls = {
                    { name = "z", isconst = true,
                        type = { _tag = "Ast.TypeString" } },
                },
                exps = { { _tag = "Ast.ExpString", value = "ready" } },
            },
        })

        assert_statements_syntax_error("const x", "AssignLocal")
        assert_statements_syntax_error("local const x =", "ExpLocal")
    end)

    it('leaves fixed-array inference to the checker and parses borrowed and owned arrays', function()

        local program = assert_parses_successfuly([[
            function f()
                local storage = foreign Item.new_array(3)
                local borrowed: foreign Item[] = foreign Item.new_array(count)
                local owner: owned Item[] = foreign Item.new_array(3)
            end
        ]])
        local stats=program[1].block.stats
        assert.is_nil(stats[1].decls[1].type)
        assert.equal("Ast.ExpForeignType",stats[1].exps[1].exp.var.exp._tag)
        assert.equal("Ast.TypeCArray",stats[2].decls[1].type._tag)
        assert.is_nil(stats[2].decls[1].type.length)
        assert.equal("Ast.TypeOwned",stats[3].decls[1].type._tag)
    end)

    it("retains ordinary initialized qualified local declarations", function()
        assert_statements_ast([[
            local object: foreign Object = source
            local first: foreign Object, second: foreign Other = a, b
        ]], {
            { _tag = "Ast.StatDecl", decls = {
                { name = "object", type = {
                    _tag = "Ast.TypeForeignName",

                    name = "Object",
                } },
            }, exps = { { _tag = "Ast.ExpVar" } } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "first", type = { _tag = "Ast.TypeForeignName" } },
                { name = "second", type = { _tag = "Ast.TypeForeignName" } },
            }, exps = {
                { _tag = "Ast.ExpVar" },
                { _tag = "Ast.ExpVar" },
            } },
        })
    end)

    it('rejects every source-written fixed C array extent', function()

        for _,extent in ipairs({"3","count","3.0","-2","1 + 2"}) do
            assert_statements_syntax_error(
                "local storage: foreign Item["..extent.."] = source", "RBracketCArray")
        end
    end)

    it('allows only empty brackets in foreign array type syntax', function()

        for _,source in ipairs({
            "function f(x: foreign Item[3]) end",
            "function f(): foreign Item[3] end",
            "foreign type Items = Item[3]",
            "record R item: foreign Item[3] end",
        }) do assert_program_syntax_error(source,"RBracketCArray") end
        assert_type_ast("foreign Item[]",{_tag="Ast.TypeCArray",length=nil,
            base={_tag="Ast.TypeForeignName",name="Item"}})
    end)

    it("can parse toplevel function declarations", function()
        assert_program_ast([[
            local function fA(): nil
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                islocal = true,
                name = "fA",
                params = {},
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            local function fB(x:foreign int): nil
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                islocal = true,
                name = "fB",
                params = {
                    { _tag = "Ast.Decl", name = "x" },
                },
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            local function fC(x:foreign int, y:foreign int): nil
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                islocal = true,
                name = "fC",
                params = {
                    { _tag = "Ast.Decl", name = "x" },
                    { _tag = "Ast.Decl", name = "y" },
                },
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })
    end)

    it('parses foreign declarations and foreign function-pointer types', function()

        local program = assert_parses_successfuly([[
            foreign function notify() return end
            foreign function apply(item: *Item, callback: function(int): int): int
                return callback(0)
            end
            foreign type Nested = function(function(int): int): void
            foreign type Variadic = function(int, ...): int
        ]])
        assert.equal("void", program[1].rettypes[1].name)
        assert.equal("Ast.TypeCPointer",program[2].params[1].type._tag)
        assert.equal("Ast.TypeForeignFunction",program[2].params[2].type._tag)
        assert.equal("Ast.TopLevelForeignTypeAlias",program[3]._tag)
        assert.equal("Ast.TypeForeignFunction",program[3].type.argtypes[1]._tag)
        assert.is_true(program[4].type.varargtype)
        assert_program_syntax_error("local foreign type X = int","TopLevelDecl")
    end)

    it("can parse toplevel method declarations", function()
        assert_program_ast([[
            function Record:fA(): nil
            end
        ]], {
            { _tag = "Ast.TopLevelMethod",
                class = "Record",
                name = "fA",
                params = {},
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            function Record:fB(x:foreign int): nil
            end
        ]], {
            { _tag = "Ast.TopLevelMethod",
                class = "Record",
                name = "fB",
                params = {
                    { _tag = "Ast.Decl", name = "x" },
                },
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            function Record:fC(x:foreign int, y:foreign int): nil
            end
        ]], {
            { _tag = "Ast.TopLevelMethod",
                class = "Record",
                name = "fC",
                params = {
                    { _tag = "Ast.Decl", name = "x" },
                    { _tag = "Ast.Decl", name = "y" },
                },
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            local function Record:fD(): nil
            end
        ]], {
            { _tag = "Ast.TopLevelMethod",
                islocal = true,
                class = "Record",
                name = "fD",
                params = {},
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })
    end)

    it("can parse toplevel record function declarations", function()
        assert_program_ast([[
            function Record.fA(): nil
            end
        ]], {
            { _tag = "Ast.TopLevelStatic",
                class = "Record",
                name = "fA",
                params = {},
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            function Record.fB(x:foreign int): nil
            end
        ]], {
            { _tag = "Ast.TopLevelStatic",
                class = "Record",
                name = "fB",
                params = {
                    { _tag = "Ast.Decl", name = "x" },
                },
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })

        assert_program_ast([[
            local function Record.fC(): nil
            end
        ]], {
            { _tag = "Ast.TopLevelStatic",
                islocal = true,
                class = "Record",
                name = "fC",
                params = {},
                block = { _tag = "Ast.StatBlock", stats = {} } },
        })
    end)

    it("omitting the return annotation yields a zero-return () function", function ()
        assert_program_ast([[
            function foo()
            end
            local function bar()
            end
        ]], {
            { _tag = "Ast.TopLevelFunc", name = "foo", rettypes = {},
              flexrettype = nil },
            { _tag = "Ast.TopLevelFunc", name = "bar", rettypes = {},
              flexrettype = nil },
        })
    end)

    it("can parse a lambda with no annotations", function()
        assert_program_ast([[
            function f(): integer
                local g = function(x) return x end
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        exps = {
                            { _tag = "Ast.ExpFunction",
                                params = {
                                    { _tag = "Ast.Decl", name = "x", type = nil },
                                },
                                rettypes = nil,
                                flexrettype = nil,
                                block = { _tag = "Ast.StatBlock" } },
                        } },
                } } },
        })
    end)

    it("can parse a lambda with a return annotation", function()
        assert_program_ast([[
            function f(): integer
                local g = function(x: integer): integer return x end
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        exps = {
                            { _tag = "Ast.ExpFunction",
                                params = {
                                    { _tag = "Ast.Decl", name = "x" },
                                },
                                rettypes = {
                                    { _tag = "Ast.TypeInteger" },
                                },
                                flexrettype = nil },
                        } },
                } } },
        })
    end)

    it("can parse a zero-param and a multi-param lambda", function()
        assert_program_ast([[
            function f(): integer
                local g = function() return 1 end
                local h = function(a, b: integer, c) return a end
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        decls = { { name = "g" } },
                        exps = {
                            { _tag = "Ast.ExpFunction", params = {} },
                        } },
                    { _tag = "Ast.StatDecl",
                        decls = { { name = "h" } },
                        exps = {
                            { _tag = "Ast.ExpFunction",
                                params = {
                                    { _tag = "Ast.Decl", name = "a", type = nil },
                                    { _tag = "Ast.Decl", name = "b" },
                                    { _tag = "Ast.Decl", name = "c", type = nil },
                                } },
                        } },
                } } },
        })
    end)

    it("distinguishes an explicit `: ()` lambda from no annotation", function()
        assert_program_ast([[
            function f(): integer
                local g = function(): () end
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        exps = {
                            { _tag = "Ast.ExpFunction", rettypes = {},
                              flexrettype = nil },
                        } },
                } } },
        })
    end)

    it("can parse a nested lambda", function()
        assert_program_ast([[
            function f(): integer
                local g = function(x: integer): integer
                    local h = function(y: integer): integer return x + y end
                    return h(x)
                end
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        exps = {
                            { _tag = "Ast.ExpFunction",
                                block = { stats = {
                                    { _tag = "Ast.StatDecl",
                                        exps = {
                                            { _tag = "Ast.ExpFunction" },
                                        } },
                                } } },
                        } },
                } } },
        })
    end)

    it("can parse a lambda in argument position", function()
        assert_program_ast([[
            function f(): integer
                apply(function(x: integer): integer return x end, 1)
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatCall",
                        callexp = { _tag = "Ast.ExpCall",
                            args = { _tag = "Ast.ArgsFunc",
                                args = {
                                    { _tag = "Ast.ExpFunction" },
                                    { _tag = "Ast.ExpInteger", value = 1 },
                                } } } },
                } } },
        })
    end)

    it("can parse a lambda in init-list position", function()
        assert_program_ast([[
            function f(): integer
                local t = { function(x: integer): integer return x end }
                return 1
            end
        ]], {
            { _tag = "Ast.TopLevelFunc",
                block = { stats = {
                    { _tag = "Ast.StatDecl",
                        exps = {
                            { _tag = "Ast.ExpInitList",
                                fields = {
                                    { _tag = "Ast.Field",
                                        exp = { _tag = "Ast.ExpFunction" } },
                                } },
                        } },
                } } },
        })
    end)

    it("can parse primitive types", function()
        assert_type_ast("nil", { _tag = "Ast.TypeNil" } )
        assert_type_ast("int", { _tag = "Ast.TypeName", name = "int" } )
    end)

    it('parses the exact contextual C99 primitive surface', function()

        for _,name in ipairs({"void","bool","char","signed char","unsigned char",
            "short","unsigned short","int","unsigned int","long","unsigned long",
            "long long","unsigned long long","float","double","long double"}) do
            assert_type_ast("foreign "..name,{_tag="Ast.TypeForeignName",name=name})
        end
        for _,name in ipairs({"signed short","signed int","signed long"}) do
            assert.falsy(parser.parse("bad.titan","local x: foreign "..name.." = nil"))
        end
    end)

    it('parses contextual primitive allocation and layout namespaces', function()

        for _,expression in ipairs({"foreign float.new_array(2)",
            "foreign unsigned long.sizeof", "foreign (*int).alignof", "foreign Packet.new(3)"}) do
            local exp = assert_expression_ast(expression,{})
            local selected = exp._tag=="Ast.ExpCall" and exp.exp or exp
            assert.equal("Ast.ExpForeignType", selected.var.exp._tag)
        end
        assert_expression_ast("char.new_array(2)",{_tag="Ast.ExpCall",
            exp={var={exp={_tag="Ast.ExpVar",var={name="char"}}}}})
        assert_expression_syntax_error("foreign int", "ForeignTypeMember")
    end)

    it("composes contextual primitives with pointers and owners", function()
        assert_type_ast("foreign const *unsigned long long", {
            _tag = "Ast.TypeCPointer",
            const = true,
            subtype = {
                _tag = "Ast.TypeForeignName",
                name = "unsigned long long",
            },
        })
        assert_type_ast("owned (const *float)[]", {
            _tag = "Ast.TypeOwned",
            subtype = {
                _tag = "Ast.TypeCArray",
                base = {
                _tag = "Ast.TypeCPointer",
                const = true,
                subtype = {
                    _tag = "Ast.TypeForeignName",
                    name = "float",
                },
                },
            },
        })
    end)

    it("can parse qualified types", function()
        assert_type_ast("foo.bar", { _tag = "Ast.TypeQualName", module = "foo", name = "bar" } )
    end)

    it('accepts AnyName only at the selected grammar boundaries', function()

        for _,name in ipairs({"when","end","function","type","interface"}) do
            assert_type_ast("module."..name,{_tag="Ast.TypeQualName",name=name})
            assert_expression_ast("module."..name,{var={_tag="Ast.VarDot",name=name}})
        end
        assert_parses_successfuly([[
            function when() end
            function R:when() end
            function R.end() end
            record R when: integer end
            union U when() end
            local: integer = 1
            local local: integer = 2
            local record: integer = 3
        ]])
        assert_program_syntax_error("function f(when: integer) end","RParPList")
    end)

    it('can parse scalar and counted owned C types', function()

        assert_type_ast("owned *Item",{_tag="Ast.TypeOwned",subtype={
            _tag="Ast.TypeCPointer",subtype={_tag="Ast.TypeForeignName",name="Item"}}})
        assert_type_ast("owned Item[]",{_tag="Ast.TypeOwned",subtype={
            _tag="Ast.TypeCArray",base={_tag="Ast.TypeForeignName",name="Item"}}})
        assert_type_ast("owned (*Item)[]",{_tag="Ast.TypeOwned",subtype={
            _tag="Ast.TypeCArray",base={_tag="Ast.TypeCPointer"}}})
        assert_type_ast("owned Handle",{_tag="Ast.TypeOwned",subtype={
            _tag="Ast.TypeForeignName",name="Handle"}})
    end)

    it("applies the option suffix to the complete owned C type", function()
        assert_type_ast("(owned *Item)?", {
            _tag = "Ast.TypeOption",
            basetype = {
                _tag = "Ast.TypeOwned",
                subtype = {
                    _tag = "Ast.TypeCPointer",
                    subtype = {
                    _tag = "Ast.TypeForeignName",
                    name = "Item",
                    },
                },
            },
        })
        assert_type_ast("(owned Item[])?", {
            _tag = "Ast.TypeOption",
            basetype = {
                _tag = "Ast.TypeOwned",
                subtype = {
                    _tag = "Ast.TypeCArray",
                    base = {
                    _tag = "Ast.TypeForeignName",
                    name = "Item",
                    },
                },
            },
        })
    end)

    it('reports malformed owned C type shapes at the owned production', function()

        -- Names are resolved before pointer/array eligibility is checked.
        assert_type_ast("owned Item",{_tag="Ast.TypeOwned"})
        assert_type_syntax_error("owned *", "TypeDecl")
        assert_type_syntax_error("owned Item[", "RBracketCArray")
        assert_type_syntax_error("owned Item[4]", "RBracketCArray")
        assert_type_syntax_error("owned (*int", "RParenTypelist")
    end)

    it('retains owned type source locations', function()

        local program=assert(parser.parse("owners.titan","local x: owned Item[]? = nil"))
        local owner=program[1].decl.type.basetype
        assert.same({filename="owners.titan",line=1,col=10},owner.loc)
        assert.same({filename="owners.titan",line=1,col=16},owner.subtype.loc)
        assert.same(owner.subtype.loc,owner.subtype.base._name_loc)
    end)

    it("can parse array types", function()
        assert_type_ast("{int}",
            { _tag = "Ast.TypeArray", isconst = { tag = "no" }, subtype =
                {_tag = "Ast.TypeName", name = "int" } } )

        assert_type_ast("{{int}}",
            { _tag = "Ast.TypeArray", isconst = { tag = "no" }, subtype =
                { _tag = "Ast.TypeArray", isconst = { tag = "no" }, subtype =
                    {_tag = "Ast.TypeName", name = "int" } } } )

        assert_type_ast("const {int}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "yes" },
            subtype = { _tag = "Ast.TypeName", name = "int" },
        })
        assert_type_ast("const {{int}}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "yes" },
            subtype = {
                _tag = "Ast.TypeArray",
                isconst = { tag = "no" },
                subtype = { _tag = "Ast.TypeName", name = "int" },
            },
        })
        assert_type_ast("{const {int}}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "no" },
            subtype = {
                _tag = "Ast.TypeArray",
                isconst = { tag = "yes" },
                subtype = { _tag = "Ast.TypeName", name = "int" },
            },
        })
        assert_type_ast("const {const {int}}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "yes" },
            subtype = {
                _tag = "Ast.TypeArray",
                isconst = { tag = "yes" },
                subtype = { _tag = "Ast.TypeName", name = "int" },
            },
        })
    end)

    it('keeps const Array, Option, and C pointer qualifiers independent', function()

        assert_type_ast("const {integer}?", {_tag="Ast.TypeOption",basetype={
            _tag="Ast.TypeArray",isconst={ tag = "yes" },subtype={_tag="Ast.TypeInteger"}}})
        assert_type_ast("const? {foreign const *int}",{_tag="Ast.TypeArray",isconst={ tag = "maybe" },
            subtype={_tag="Ast.TypeCPointer",const=true}})
        assert_type_ast("foreign const int[]",{_tag="Ast.TypeCArray",const=true})
        assert_type_ast("(foreign const *int)?",{_tag="Ast.TypeOption",
            basetype={_tag="Ast.TypeCPointer",const=true}})
    end)

    it("can parse const? (maybe-const) Array types", function()
        assert_type_ast("const? {int}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "maybe" },
            subtype = { _tag = "Ast.TypeName", name = "int" },
        })
        assert_type_ast("const? {{int}}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "maybe" },
            subtype = {
                _tag = "Ast.TypeArray",
                isconst = { tag = "no" },
                subtype = { _tag = "Ast.TypeName", name = "int" },
            },
        })
        assert_type_ast("const? {integer}?", {
            _tag = "Ast.TypeOption",
            basetype = {
                _tag = "Ast.TypeArray",
                isconst = { tag = "maybe" },
                subtype = { _tag = "Ast.TypeInteger" },
            },
        })
        assert_type_ast("const? {integer?}", {
            _tag = "Ast.TypeArray",
            isconst = { tag = "maybe" },
            subtype = {
                _tag = "Ast.TypeOption",
                basetype = { _tag = "Ast.TypeInteger" },
            },
        })
    end)

    it("rejects the obsolete const Array placement and const Maps", function()
        assert_type_syntax_error("{const integer}", "RCurlyType")
        assert_type_syntax_error("const {integer: string}", "ConstMap")
        assert_type_syntax_error("const? {integer: string}", "ConstMap")
        assert_type_syntax_error("const {}", "TypeConstArray")
        assert_type_syntax_error("const? {}", "TypeConstArray")
        assert_type_syntax_error("const {integer", "RCurlyType")
        assert_type_syntax_error("const? {integer", "RCurlyType")
    end)

    it("can parse map types", function()
        assert_type_ast("{int: string}",
            { _tag = "Ast.TypeMap",
              keystype = {_tag = "Ast.TypeName", name = "int" },
              valuestype = {_tag = "Ast.TypeString" } } )

        assert_type_ast("{{int:string}:{string:int}}",
            { _tag = "Ast.TypeMap",
              keystype = { _tag = "Ast.TypeMap",
                  keystype = {_tag = "Ast.TypeName", name = "int" },
                  valuestype = {_tag = "Ast.TypeString" } },
              valuestype = { _tag = "Ast.TypeMap",
                  keystype = {_tag = "Ast.TypeString" },
                  valuestype = {_tag = "Ast.TypeName", name = "int" } } } )
    end)

    it("can parse option types", function()
        assert_type_ast("integer?",
            { _tag = "Ast.TypeOption",
              basetype = {_tag = "Ast.TypeInteger" } } )

        assert_type_ast("boolean?",
              { _tag = "Ast.TypeOption",
                basetype = {_tag = "Ast.TypeBoolean" } } )

        assert_type_ast("float?",
                { _tag = "Ast.TypeOption",
                  basetype = {_tag = "Ast.TypeFloat" } } )

        assert_type_ast("string?",
                  { _tag = "Ast.TypeOption",
                    basetype = {_tag = "Ast.TypeString" } } )

        assert_type_ast("Foo?",
                { _tag = "Ast.TypeOption",
                  basetype = {_tag = "Ast.TypeName" } } )

        assert_type_ast("foo.Bar?",
                { _tag = "Ast.TypeOption",
                  basetype = {_tag = "Ast.TypeQualName" } } )

        assert_type_ast("{integer}?",
              { _tag = "Ast.TypeOption",
                basetype = {_tag = "Ast.TypeArray" } } )

        assert_type_ast("{integer: string}?",
                { _tag = "Ast.TypeOption",
                  basetype = {_tag = "Ast.TypeMap" } } )

        assert_type_ast("{{int:string}:{string:int}}",
            { _tag = "Ast.TypeMap",
              keystype = { _tag = "Ast.TypeMap",
                  keystype = {_tag = "Ast.TypeName", name = "int" },
                  valuestype = {_tag = "Ast.TypeString" } },
              valuestype = { _tag = "Ast.TypeMap",
                  keystype = {_tag = "Ast.TypeString" },
                  valuestype = {_tag = "Ast.TypeName", name = "int" } } } )
    end)

    describe("can parenthesize any single type", function()
        it("keeps grouping transparent and permits the outer option suffix", function()
            for _, spelling in ipairs({"(T)", "(((T)))"}) do
                assert_type_ast(spelling, {
                    _tag = "Ast.TypeName", name = "T", typeargs = {},
                })
            end
            for _, spelling in ipairs({"(T)?", "((T)?)", "(((T?)))"}) do
                assert_type_ast(spelling, {
                    _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "T" },
                })
            end

            local source = "local type Wrapped = mod.Item"
            local typ = assert(parser.parse("grouped.titan", source))[1].type
            assert.same({filename = "grouped.titan", line = 1,
                col = source:find("mod", 1, true)}, typ.loc)
            assert.are.equal(source:find("Item", 1, true), typ._name_loc.col)
        end)

        it("groups containers, qualifiers, and generic arguments", function()
            assert_type_ast("({(string): ((T)?)})?", {
                _tag = "Ast.TypeOption",
                basetype = {
                    _tag = "Ast.TypeMap",
                    keystype = { _tag = "Ast.TypeString" },
                    valuestype = { _tag = "Ast.TypeOption",
                        basetype = { _tag = "Ast.TypeName", name = "T" } },
                },
            })
            assert_type_ast("(const? {(T)})?", {
                _tag = "Ast.TypeOption",
                basetype = { _tag = "Ast.TypeArray", isconst = { tag = "maybe" },
                    subtype = { _tag = "Ast.TypeName", name = "T" } },
            })
            assert_type_ast("mod.Box<|{T}?|>", {
                _tag = "Ast.TypeQualName", module = "mod", name = "Box",
                typeargs = { { _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeArray",
                        subtype = { _tag = "Ast.TypeName", name = "T" } } } },
            })
            assert_expression_ast("make<|T?|>()", {
                _tag = "Ast.ExpCall", typeargs = { {
                    _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "T" },
                } },
            })
            assert_expression_ast("item as (T)?", {
                _tag = "Ast.ExpCast", target = {
                    _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "T" },
                },
            })
        end)

        it("distinguishes optional functions from optional parameters and results", function()
            assert_type_ast("function (T?): (U?)", {
                _tag = "Ast.TypeFunction",
                argtypes = { { _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "T" } } },
                rettypes = { { _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "U" } } },
                varargtype = nil, flexrettype = nil,
            })
            assert_type_ast("(function (T): (U))?", {
                _tag = "Ast.TypeOption",
                basetype = { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "T" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "U" } },
                    varargtype = nil, flexrettype = nil },
            })
            assert_type_ast("function (function (T): (U)): (V?)", {
                _tag = "Ast.TypeFunction",
                argtypes = { { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "T" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "U" } } } },
                rettypes = { { _tag = "Ast.TypeOption",
                    basetype = { _tag = "Ast.TypeName", name = "V" } } },
            })
        end)

        it("keeps grouped type-argument and callable lists dense", function()
            local call = assert_expression_ast("make<|function (T): (U?), V?|>()", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeFunction" },
                    { _tag = "Ast.TypeOption" } },
            })
            assert.same({call.typeargs[1], call.typeargs[2]}, call.typeargs)
            local callable = call.typeargs[1]
            assert.same({callable.argtypes[1]}, callable.argtypes)
            assert.same({callable.rettypes[1]}, callable.rettypes)
            assert.same({}, callable.argtypes[1].typeargs)
            assert.same({}, callable.rettypes[1].basetype.typeargs)
            assert.same({}, call.typeargs[2].basetype.typeargs)
        end)

        it("groups individual return types without turning result lists into types", function()
            assert_program_ast([[
                function one(): T? end
                function callback(): (function (T): (U))? end
                function many(): (T, U?, ...: ({V})) end
            ]], {
                { _tag = "Ast.TopLevelFunc", name = "one",
                    rettypes = { { _tag = "Ast.TypeOption",
                        basetype = { _tag = "Ast.TypeName", name = "T" } } },
                    flexrettype = nil },
                { _tag = "Ast.TopLevelFunc", name = "callback",
                    rettypes = { { _tag = "Ast.TypeOption",
                        basetype = { _tag = "Ast.TypeFunction" } } },
                    flexrettype = nil },
                { _tag = "Ast.TopLevelFunc", name = "many",
                    rettypes = {
                        { _tag = "Ast.TypeName", name = "T" },
                        { _tag = "Ast.TypeOption",
                            basetype = { _tag = "Ast.TypeName", name = "U" } },
                    },
                    flexrettype = { _tag = "Ast.TypeArray",
                        subtype = { _tag = "Ast.TypeName", name = "V" } } },
            })
        end)

        it('groups foreign function types and pointer or owned payloads', function()

        assert_type_ast("foreign function(int): int",{_tag="Ast.TypeForeignFunction",
            argtypes={{_tag="Ast.TypeForeignName",name="int"}},
            rettypes={{_tag="Ast.TypeForeignName",name="int"}}})
        assert_type_ast("foreign const *(function(int): int)",{_tag="Ast.TypeCPointer",
            const=true,subtype={_tag="Ast.TypeForeignFunction"}})
        assert_type_ast("owned *(*Item)",{_tag="Ast.TypeOwned",subtype={
            _tag="Ast.TypeCPointer",subtype={_tag="Ast.TypeCPointer"}}})
        assert_type_ast("function(foreign *int): foreign int",{_tag="Ast.TypeFunction",
            argtypes={{_tag="Ast.TypeCPointer"}},rettypes={{_tag="Ast.TypeForeignName"}}})
    end)

        it('reports malformed groups and bare type lists as syntax errors', function()

        assert_type_syntax_error("()", "LParenType")
        assert_type_syntax_error("(T,U)", "RParenTypelist")
        assert_type_syntax_error("((T,U))", "RParenTypelist")
        assert_type_syntax_error("(...:T)", "LParenType")
        for _,spelling in ipairs({"function(): ()?", "function(): (T,U)?",
            "function(): (...:T)?"}) do
            assert_type_syntax_error(spelling,"OptionTypeList")
        end
        assert_type_syntax_error("(T", "RParenTypelist")
        assert_type_syntax_error("(T)??", "fail")
    end)
    end)

    describe("can parse generic type applications", function()
        it("retains direct and qualified applications with nested closers",
        function()
            assert_type_ast("Pair<|integer, string|>", {
                _tag = "Ast.TypeName",
                name = "Pair",
                typeargs = {
                    { _tag = "Ast.TypeInteger" },
                    { _tag = "Ast.TypeString" },
                },
            })
            assert_type_ast("mod.Outer<|mod.Inner<|T|>|>", {
                _tag = "Ast.TypeQualName",
                module = "mod",
                name = "Outer",
                typeargs = {
                    {
                        _tag = "Ast.TypeQualName",
                        module = "mod",
                        name = "Inner",
                        typeargs = {
                            { _tag = "Ast.TypeName", name = "T", typeargs = {} },
                        },
                    },
                },
            })
        end)

        it("binds applications more tightly than the option suffix", function()
            assert_type_ast("Pair<|T, {mod.Item}|>?", {
                _tag = "Ast.TypeOption",
                basetype = {
                    _tag = "Ast.TypeName",
                    name = "Pair",
                    typeargs = {
                        { _tag = "Ast.TypeName", name = "T", typeargs = {} },
                        {
                            _tag = "Ast.TypeArray",
                            subtype = {
                                _tag = "Ast.TypeQualName",
                                module = "mod",
                                name = "Item",
                                typeargs = {},
                            },
                        },
                    },
                },
            })
        end)

        it("always records an explicit type-argument list", function()
            local program = assert_parses_successfuly([[
                local direct: Plain = nil
                local qualified: mod.Plain = nil
            ]])
            assert.are.same({}, program[1].decl.type.typeargs)
            assert.are.same({}, program[2].decl.type.typeargs)
        end)
    end)

    describe("can parse function types", function()
        it("with parameter lists of length = 0", function()
            assert_type_ast("function (): ()",
                { _tag = "Ast.TypeFunction",
                    argtypes = { },
                    rettypes = { } } )
        end)

        it("with parameter lists of length = 1", function()
            assert_type_ast("function (a): (b)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "a" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "b" } } } )
        end)

        it("with parameter lists of length >= 2 ", function()
            assert_type_ast("function (a, b): (c, d, e)",
                { _tag = "Ast.TypeFunction",
                    argtypes = {
                        { _tag = "Ast.TypeName", name = "a" },
                        { _tag = "Ast.TypeName", name = "b" },
                    },
                    rettypes = {
                        { _tag = "Ast.TypeName", name = "c" },
                        { _tag = "Ast.TypeName", name = "d" },
                        { _tag = "Ast.TypeName", name = "e" },
                    }
                 })
        end)

        it("with an unparenthesized single return type", function()
            assert_type_ast("function(a): b",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "a" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "b" } } } )
        end)


        it("nests function result types explicitly", function()
            local ast1 = {
                _tag = "Ast.TypeFunction",
                argtypes = {
                    { _tag = "Ast.TypeName", name = "a" } },
                rettypes = {
                    { _tag = "Ast.TypeFunction",
                        argtypes = { { _tag = "Ast.TypeName", name = "b" } },
                        rettypes = { { _tag = "Ast.TypeName", name = "c" } } } } }

            local ast2 = {
                _tag = "Ast.TypeFunction",
                argtypes = {
                    { _tag = "Ast.TypeFunction",
                        argtypes = { { _tag = "Ast.TypeName", name = "a" } },
                        rettypes = { { _tag = "Ast.TypeName", name = "b" } } } },
                rettypes = {
                    { _tag = "Ast.TypeName", name = "c" } } }

            assert_type_ast("function(a): function(b): c",   ast1)
            assert_type_ast("function(a): (function(b): c)", ast1)
            assert_type_ast("function (function (a): (b)): (c)", ast2)

            local function_result = assert_parses_successfuly(
                "local function f(): function (a): (function (b): (c)) end")
            assert_is_subset(ast1, function_result[1].rettypes[1])
        end)

        it("and '->' has higher precedence than ','", function()
            assert_type_ast("function (a, function (b): (c), d): (e)",
                { _tag = "Ast.TypeFunction",
                    argtypes = {
                        { _tag = "Ast.TypeName", name = "a" },
                        { _tag = "Ast.TypeFunction",
                          argtypes = { { _tag = "Ast.TypeName", name = "b" } },
                          rettypes = { { _tag = "Ast.TypeName", name = "c" } } },
                        { _tag = "Ast.TypeName", name = "d" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "e" } } } )
        end)
    end)

    it("can parse values", function()
        assert_expression_ast("nil",   { _tag = "Ast.ExpNil" })
        assert_expression_ast("false", { _tag = "Ast.ExpBool", value = false })
        assert_expression_ast("true",  { _tag = "Ast.ExpBool", value = true })
        assert_expression_ast("10",    { _tag = "Ast.ExpInteger", value = 10})
        assert_expression_ast("10.0",  { _tag = "Ast.ExpFloat", value = 10.0})
        assert_expression_ast("'asd'", { _tag = "Ast.ExpString", value = "asd" })
    end)

    it("can parse variables", function()
        assert_expression_ast("y", { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarName", name = "y" }})
    end)

    it("can parse parenthesized expressions", function()
        assert_expression_ast("((1))", { _tag = "Ast.ExpInteger", value = 1 })
    end)

    it("can parse table constructors", function()
        assert_expression_ast("{}",
            { _tag = "Ast.ExpInitList", fields = {} })

        assert_expression_ast("{10,20,30}",
            { _tag = "Ast.ExpInitList", fields = {
                { exp = { value = 10 } },
                { exp = { value = 20 } },
                { exp = { value = 30 } }, }})

        assert_expression_ast("{40;50;60;}", -- (semicolons)
            { _tag = "Ast.ExpInitList", fields = {
                { exp = { value = 40 } },
                { exp = { value = 50 } },
                { exp = { value = 60 } }, }})
    end)

    describe("can parse while statements", function()
        assert_statements_ast("while true do end", {
            { _tag = "Ast.StatWhile",
              condition = { _tag = "Ast.ExpBool" },
              block = { _tag = "Ast.StatBlock" } }
        })
    end)

    describe("can parse repeat-until statements", function()
        assert_statements_ast("repeat until false", {
            { _tag = "Ast.StatRepeat",
              block = { _tag = "Ast.StatBlock" },
              condition = { _tag = "Ast.ExpBool" }, }
        })
    end)

    describe("can parse break statements", function()
        assert_statements_ast("while true do break end", {
            { _tag = "Ast.StatWhile",
              block = { _tag = "Ast.StatBlock",
                        stats = { { _tag = "Ast.StatBreak" } } } }
        })
    end)

    describe("can parse if statements", function()
        assert_statements_ast("if 10 then end", {
            { _tag = "Ast.StatIf",
                thens = {
                    { _tag = "Ast.Then", condition = { value = 10 } },
                },
              elsestat = nil }
        })

        assert_statements_ast("if 20 then else end", {
            { _tag = "Ast.StatIf",
                thens = {
                    { _tag = "Ast.Then", condition = { value = 20 } },
                },
                elsestat = { _tag = "Ast.StatBlock" } }
        })

        assert_statements_ast("if 30 then elseif 40 then end", {
            { _tag = "Ast.StatIf",
                thens = {
                    { _tag = "Ast.Then", condition = { value = 30 } },
                    { _tag = "Ast.Then", condition = { value = 40 } },
                },
                elsestat = nil }
        })

        assert_statements_ast("if 50 then elseif 60 then else end", {
            { _tag = "Ast.StatIf",
              thens = {
                    { _tag = "Ast.Then", condition = { value = 50 } },
                    { _tag = "Ast.Then", condition = { value = 60 } },
                },
                elsestat = { _tag = "Ast.StatBlock" } }
        })
    end)

    describe("can parse case statements", function()
        it("retains ordered positional prefixes and named aliases", function()
            assert_statements_ast([[
                case message
                when item(first, second) then use(first, second)
                when item(first) then use(first)
                when item{ second; alias = end, first } then use(alias)
                when item{} then stop()
                end
            ]], {{
                _tag = "Ast.StatCase",
                arms = {
                    { named = false, bindings = {
                        { name = "first", type = nil },
                        { name = "second", type = nil },
                    } },
                    { named = false, bindings = {{ name = "first" }} },
                    { named = true, bindings = {
                        { name = "second", part = "second" },
                        { name = "alias", part = "end" },
                        { name = "first", part = "first" },
                    } },
                    { named = true, bindings = {} },
                },
            }})
        end)

        it("accepts optional separators between named case bindings", function()
            assert_statements_ast("case x when item{ one two alias = end; } then end", {{
                arms = {{ bindings = {
                    { name = "one", part = "one" },
                    { name = "two", part = "two" },
                    { name = "alias", part = "end" },
                } }},
            }})
        end)

        it("requires aliases for keyword parts and labels malformed bindings", function()
            local cases = {
                { "item{end}", "RCurlyCaseVariant" },
                { "item{end = first}", "RCurlyCaseVariant" },
                { "item{alias = }", "NameCasePart" },
                { "item{alias", "RCurlyCaseVariant" },
                { "item{one,,two}", "RCurlyCaseVariant" },
                { "item(first,)", "NameCaseBinding" },
                { "item(first end)", "RParenVariant" },
                { "item(end)", "NameCaseBinding" },
                { "item", "LParenCaseVariant" },
            }
            for _, test in ipairs(cases) do
                assert_statements_syntax_error(
                    "case x when " .. test[1] .. " then end", test[2])
            end
        end)

        it("rejects duplicate part references even when aliases differ", function()
            for _, bindings in ipairs({ "one, one", "one alias = one",
                                         "a = end; b = end" }) do
                assert_statements_syntax_error(
                    "case x when item{" .. bindings .. "} then end", "DuplicateCasePart")
            end
            local tree, err = parser.parse("duplicate.titan", [[
function f(x: value)
  case x when item{ first, alias = first } then end
end]])
            assert.is_false(tree)
            assert.are.equal("DuplicateCasePart", err.label)
            assert.are.equal(2, err.loc.line)
            assert.are.equal(36, err.loc.col)
        end)

        it("parses one or more when arms, bindings, and else", function()
            assert_statements_ast([[
                case msg
                when quit() then
                    stop()
                when move(delta) then
                    apply(delta)
                else
                    ignore()
                end
            ]], {
                {
                    _tag = "Ast.StatCase",
                    exp = {
                        _tag = "Ast.ExpVar",
                        var = { _tag = "Ast.VarName", name = "msg" },
                    },
                    arms = {
                        {
                            _tag = "Ast.CaseArm",
                            name = "quit",
                            bindings = {},
                            named = false,
                            block = { _tag = "Ast.StatBlock" },
                        },
                        {
                            _tag = "Ast.CaseArm",
                            name = "move",
                            bindings = {{
                                _tag = "Ast.Decl",
                                name = "delta",
                                type = nil,
                                option = false,
                            }},
                            named = false,
                            block = { _tag = "Ast.StatBlock" },
                        },
                    },
                    elseblock = { _tag = "Ast.StatBlock" },
                },
            })
        end)

        it("keeps each arm and else as an independent full block", function()
            assert_statements_ast([[
                case msg
                when first() then
                    defer cleanup_body()
                    body()
                catch
                    defer cleanup_catch()
                    recover()
                when second() then
                    if ready then
                        nested()
                    end
                when third() then
                    later()
                else
                    defer cleanup_else_body()
                    fallback()
                catch
                    defer cleanup_else_catch()
                    recover_else()
                end
            ]], {
                {
                    _tag = "Ast.StatCase",
                    arms = {
                        {
                            name = "first",
                            block = {
                                _tag = "Ast.StatTry",
                                block = {
                                    _tag = "Ast.StatBlock",
                                    stats = {
                                        {
                                            _tag = "Ast.StatTry",
                                            finallyblock = {
                                                _tag = "Ast.StatBlock",
                                            },
                                        },
                                    },
                                },
                                catchblock = {
                                    _tag = "Ast.StatBlock",
                                    stats = {
                                        {
                                            _tag = "Ast.StatTry",
                                            finallyblock = {
                                                _tag = "Ast.StatBlock",
                                            },
                                        },
                                    },
                                },
                            },
                        },
                        {
                            name = "second",
                            block = {
                                _tag = "Ast.StatBlock",
                                stats = {
                                    { _tag = "Ast.StatIf" },
                                },
                            },
                        },
                        {
                            name = "third",
                            block = { _tag = "Ast.StatBlock" },
                        },
                    },
                    elseblock = {
                        _tag = "Ast.StatTry",
                        block = {
                            _tag = "Ast.StatBlock",
                            stats = {
                                {
                                    _tag = "Ast.StatTry",
                                    finallyblock = {
                                        _tag = "Ast.StatBlock",
                                    },
                                },
                            },
                        },
                        catchblock = {
                            _tag = "Ast.StatBlock",
                            stats = {
                                {
                                    _tag = "Ast.StatTry",
                                    finallyblock = {
                                        _tag = "Ast.StatBlock",
                                    },
                                },
                            },
                        },
                    },
                },
            })
        end)

        it("parses nested cases inside loops and protected blocks", function()
            assert_statements_ast([[
                while running do
                    do
                        defer cleanup()
                        case outer
                        when item() then
                            case inner
                            when done() then
                                break
                            end
                        end
                    end
                end
            ]], {
                {
                    _tag = "Ast.StatWhile",
                    block = {
                        _tag = "Ast.StatBlock",
                        stats = {
                            {
                                _tag = "Ast.StatBlock",
                                stats = {
                                    {
                                        _tag = "Ast.StatTry",
                                        block = {
                                            stats = {
                                                {
                                                    _tag = "Ast.StatCase",
                                                    arms = {
                                                        {
                                                            block = {
                                                                stats = {
                                                                    {
                                                                        _tag = "Ast.StatCase",
                                                                    },
                                                                },
                                                            },
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            })
        end)

        it("keeps cases inside deferred cleanup blocks", function()
            assert_statements_ast([[
                defer do
                    case pending
                    when item() then
                        release()
                    end
                end
                work()
            ]], {
                {
                    _tag = "Ast.StatTry",
                    finallyblock = {
                        _tag = "Ast.StatBlock",
                        stats = {
                            {
                                _tag = "Ast.StatBlock",
                                stats = {
                                    { _tag = "Ast.StatCase" },
                                },
                            },
                        },
                    },
                },
            })
        end)
    end)

    it("can parse do-while blocks", function()
        assert_statements_ast([[
            do
                local x = 10; x = 11
                print("Hello", "World")
            end
        ]], {
            { _tag = "Ast.StatBlock",
                stats = {
                    { _tag = "Ast.StatDecl",
                        decls = {{ name = "x" }},
                        exps = {{ value = 10 }} },
                    { _tag = "Ast.StatAssign",
                        vars = {{ name = "x" }},
                        exps = {{ value = 11 }} },
                    { _tag = "Ast.StatCall",
                        callexp = { _tag = "Ast.ExpCall" } } } },
        })
    end)

    it("can parse multiple variable declaration", function()
        assert_statements_ast([[
            local x, y = 10, 20
        ]], {
            { _tag = "Ast.StatDecl",
                        decls = {{ name = "x" }, { name = "y" }},
                        exps = {{ value = 10 }, { value = 20 }} }
        })
    end)

    it("requires local binders and complete present initializers", function()
        assert_statements_syntax_error([[
            local  = 10
        ]], "DeclLocal")
        assert_statements_syntax_error([[
            local x, = 10, 20
        ]], "DeclParList")
        assert_statements_syntax_error([[
            local x =
        ]], "ExpLocal")
        assert_statements_syntax_error([[
            local x, y = 10,
        ]], "ExpExpList")
    end)

    it("can parse numeric for loops", function()
        assert_statements_ast([[
            for i = 1, 2, 3 do
                x = i
            end
        ]], {
            { _tag = "Ast.StatFor",
              block = {
                stats = {
                  { _tag = "Ast.StatAssign",
                    exps = {{ var = { _tag = "Ast.VarName", name = "i" }} },
                    vars = {{ _tag = "Ast.VarName", name = "x" }} } } },
              decl = { _tag = "Ast.Decl", name = "i", type = nil },
              finish = { _tag = "Ast.ExpInteger", value = 2 },
              inc =    { _tag = "Ast.ExpInteger", value = 3 },
              start =  { _tag = "Ast.ExpInteger", value = 1 } },
        })
    end)

    it("can parse generic for loops", function()
        assert_statements_ast([[
            for x in iter do
                y = x
            end
        ]], {
            { _tag = "Ast.StatForIn",
              decls = {{ _tag = "Ast.Decl", name = "x", type = nil }},
              exps = {{ var = { _tag = "Ast.VarName", name = "iter" }}},
              block = {
                stats = {
                  { _tag = "Ast.StatAssign",
                    exps = {{ var = { _tag = "Ast.VarName", name = "x" }} },
                    vars = {{ _tag = "Ast.VarName", name = "y" }} } } } },
        })
    end)

    it("can parse typed multi-variable generic for loops", function()
        assert_statements_ast([[
            for k: integer, v: string in next, ctx, init do
                use(k, v)
            end
        ]], {
            { _tag = "Ast.StatForIn",
              decls = {
                { _tag = "Ast.Decl", name = "k",
                  type = { _tag = "Ast.TypeInteger" } },
                { _tag = "Ast.Decl", name = "v",
                  type = { _tag = "Ast.TypeString" } },
              },
              exps = {
                { var = { _tag = "Ast.VarName", name = "next" }},
                { var = { _tag = "Ast.VarName", name = "ctx" }},
                { var = { _tag = "Ast.VarName", name = "init" }},
              },
              block = { stats = {{ _tag = "Ast.StatCall" }} } },
        })
    end)

    it("can parse return statements", function()
        assert_statements_ast("return", {
            { _tag = "Ast.StatReturn", exps = {} }})

        assert_statements_ast("return;", {
            { _tag = "Ast.StatReturn", exps = {} }})

        assert_statements_ast("return x", {
            { _tag = "Ast.StatReturn", exps = {{ _tag = "Ast.ExpVar" }} },
        })
        assert_statements_ast("return x;", {
            { _tag = "Ast.StatReturn", exps = {{ _tag = "Ast.ExpVar" }} },
        })
        assert_statements_ast("return x, y", {
            { _tag = "Ast.StatReturn", exps = {{ _tag = "Ast.ExpVar" },{ _tag = "Ast.ExpVar" }} },
        })
        assert_statements_ast("return x, y;", {
            { _tag = "Ast.StatReturn", exps = {{ _tag = "Ast.ExpVar" },{ _tag = "Ast.ExpVar" }} },
        })

        assert_statements_ast([[
            local x = 1
            return
        ]], {
            { _tag = "Ast.StatDecl",
                exps = { { _tag = "Ast.ExpInteger", value = 1 } } },
            { _tag = "Ast.StatReturn", exps = {} },
        })
    end)

    it("requires that return statements be the last in the block", function()
        assert_statements_syntax_error([[
            return 10
            return 11
        ]], "EndFunc")
    end)

    it("does not allow extra semicolons after a return", function()
        assert_statements_syntax_error([[
            return;;
        ]], "EndFunc")
    end)

    it("can parse parenthesis around calls", function()
        assert_expression_ast([[ (f()) ]],
            { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpCall" } })

        assert_expression_ast([[ ((f())) ]],
            { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpCall" } })

        assert_expression_ast([[ (o:m ()) ]],
            { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpCall" } })

        assert_expression_ast([[ ((o:m ())) ]],
            { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpCall" } })
    end)

    it("can parse binary and unary operators", function()
        assert_expression_ast([[not 1 or 2 and 3 and 4]],
            { op = "or",
                lhs = { op = "not", exp = { value = 1 } },
                rhs = { op = "and",
                    lhs = { op = "and",
                        lhs = { value = 2 },
                        rhs = { value = 3 } },
                    rhs = { value = 4} } })

        assert_expression_ast([[(1 <= 2) == (4 < 5) == (6 ~= 7)]],
            { op = "==",
                lhs = { op = "==",
                    lhs = { op = "<=",
                        lhs = { value = 1 },
                        rhs = { value = 2 } },
                    rhs = { op = "<",
                        lhs = { value = 4 },
                        rhs = { value = 5 } } },
                rhs = { op = "~=",
                    lhs = { value = 6 },
                    rhs = { value = 7 } } })

        assert_expression_ast([[~~1 ~ 2 << 3 >> 4 | 5 & 6]],
            { op = "|",
                lhs = { op = "~",
                    lhs = { op = "~", exp = { op = "~", exp = { value = 1 } } },
                    rhs = { op = ">>",
                        lhs = { op = "<<",
                            lhs = { value = 2 },
                            rhs = { value = 3 } } } },
                rhs = { op = "&",
                    lhs = { value = 5 },
                    rhs = { value = 6 } } })

        assert_expression_ast([[- -1 / 2 + 3 * # "a"]],
            { op = "+",
                lhs = { op = "/",
                    lhs = { op = "-", exp = { op = "-", exp = { value = 1 } } },
                    rhs = { value = 2 } },
                rhs = { op = "*",
                    lhs = { value = 3 },
                    rhs = { op = "#", exp = { value = "a" } } } })

        -- concatenation is right associative
        -- and has less precedence than prefix operators
        assert_expression_ast([[-x .. -y .. -z]],
            { _tag = "Ast.ExpConcat", exps = {
                { op = "-", exp = { var = { name = "x" } } },
                { op = "-", exp = { var = { name = "y" } } },
                { op = "-", exp = { var = { name = "z" } } },
            } })

        -- exponentiation is also right associative
        -- but it has a higher precedence than prefix operators
        assert_expression_ast([[-1 ^ -2 ^ 3 * 4]],
            { op = "*",
                lhs = { op = "-",
                    exp = { op = "^",
                        lhs = { value = 1 },
                        rhs = { op = "-",
                            exp = { op = "^",
                                lhs = { value = 2 },
                                rhs = { value = 3 } } } } },
                 rhs = { value = 4 } })
    end)

    it("constant folds concatenation expressions", function()
        assert_expression_ast([["a" .. "b" .. "c"]],
            { _tag = "Ast.ExpString", value = "abc" })

        assert_expression_ast([[1 .. 2]],
            { _tag = "Ast.ExpString", value = "12" })

        assert_expression_ast([[2.5 .. 1.5]],
            { _tag = "Ast.ExpString", value = "2.51.5" })

        assert_expression_ast([["a" .. 2]],
            { _tag = "Ast.ExpString", value = "a2" })

        assert_expression_ast([[2 .. "a"]],
            { _tag = "Ast.ExpString", value = "2a" })
    end)

    it("can parse suffix operators", function()
        assert_expression_ast([[ - x()()[2] ^ 3]],
            { _tag = "Ast.ExpUnop", op = "-",
                exp = { _tag = "Ast.ExpBinop", op = "^",
                    rhs = { value = 3 },
                    lhs = { _tag = "Ast.ExpVar", var = {
                        _tag = "Ast.VarBracket",
                        exp2 = { value = 2 },
                        exp1 = { _tag = "Ast.ExpCall",
                            args = { _tag = "Ast.ArgsFunc" },
                            exp = { _tag = "Ast.ExpCall",
                                args = { _tag = "Ast.ArgsFunc" },
                                exp = { _tag = "Ast.ExpVar",
                                    var = { _tag = "Ast.VarName", name = "x" }}}}}}}})
    end)

    it("keeps parenthesized and bare-string function calls positional", function()
        assert_expression_ast([[ f() ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = { } } })

        assert_expression_ast([[ f "qwe" ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = {
                    { _tag = "Ast.ExpString", value = "qwe" } } } })
    end)

    it("parses spaced, adjacent, and empty named function calls", function()
        local one_field = { _tag = "Ast.ExpCall", args = {
            _tag = "Ast.ArgsNamedFunc", fields = {
                { _tag = "Ast.Field", name = "x",
                  exp = { _tag = "Ast.ExpInteger", value = 1 } } } } }

        assert_expression_ast([[ f { x = 1 } ]], one_field)
        assert_expression_ast([[ f{x = 1} ]], one_field)

        local empty = { _tag = "Ast.ExpCall", args = {
            _tag = "Ast.ArgsNamedFunc", fields = { } } }
        assert_expression_ast([[ f {} ]], empty)
        assert_expression_ast([[ f{} ]], empty)

        assert_expression_ast([[ m.f{} ]], {
            _tag = "Ast.ExpCall",
            exp = { _tag = "Ast.ExpVar", var = {
                _tag = "Ast.VarDot", name = "f" } },
            args = { _tag = "Ast.ArgsNamedFunc", fields = { } },
        })
    end)

    it("retains named function arguments in source order", function()
        assert_expression_ast([[
            f { second = mark(2); first = mark(1), third = 3, }
        ]], {
            _tag = "Ast.ExpCall",
            args = { _tag = "Ast.ArgsNamedFunc", fields = {
                { name = "second", exp = {
                    _tag = "Ast.ExpCall", args = { args = {
                        { _tag = "Ast.ExpInteger", value = 2 } } } } },
                { name = "first", exp = {
                    _tag = "Ast.ExpCall", args = { args = {
                        { _tag = "Ast.ExpInteger", value = 1 } } } } },
                { name = "third", exp = {
                    _tag = "Ast.ExpInteger", value = 3 } },
            } },
        })
    end)

    it('accepts reserved-word labels and declarations but keeps local Name binders', function()

        assert_expression_ast("f{end=1, function=2}",{_tag="Ast.ExpCall",args={
            _tag="Ast.ArgsNamedFunc",fields={{name="end"},{name="function"}}}})
        assert_parses_successfuly("function end() end record R end: integer end")
        assert_program_syntax_error("function f() local end = 1 end","DeclLocal")
    end)

    it("keeps parenthesized and bare-string method calls positional", function()
        assert_expression_ast([[ o:m () ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsMethod", args = { } } })

        assert_expression_ast([[ o:m "asd" ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsMethod", args = {
                    { _tag = "Ast.ExpString", value = "asd" } } } })
    end)

    it("parses spaced, adjacent, empty, and reordered named method calls",
    function()
        local nonempty = { _tag = "Ast.ExpCall", args = {
            _tag = "Ast.ArgsNamedMethod", method = "m", fields = {
                { name = "dy", exp = { value = 20 } },
                { name = "dx", exp = { value = 10 } },
            } } }
        assert_expression_ast([[ o:m { dy = 20, dx = 10 } ]], nonempty)
        assert_expression_ast([[ o:m{dy = 20; dx = 10;} ]], nonempty)

        local empty = { _tag = "Ast.ExpCall", args = {
            _tag = "Ast.ArgsNamedMethod", method = "m", fields = { } } }
        assert_expression_ast([[ o:m {} ]], empty)
        assert_expression_ast([[ o:m{} ]], empty)
    end)

    describe("can parse generic call suffixes", function()
        it("keeps inferred and explicit function-call arguments distinct",
        function()
            local inferred = assert_expression_ast("f(x)", {
                _tag = "Ast.ExpCall",
                typeargs = {},
                args = { _tag = "Ast.ArgsFunc" },
            })
            assert.are.same({}, inferred.typeargs)

            assert_expression_ast("f <| Outer<|Inner<|T|>|> |> (x)", {
                _tag = "Ast.ExpCall",
                exp = { var = { name = "f" } },
                typeargs = {
                    {
                        _tag = "Ast.TypeName",
                        name = "Outer",
                        typeargs = { {
                            _tag = "Ast.TypeName",
                            name = "Inner",
                            typeargs = { {
                                _tag = "Ast.TypeName",
                                name = "T",
                                typeargs = {},
                            } },
                        } },
                    },
                },
                args = {
                    _tag = "Ast.ArgsFunc",
                    args = { { var = { name = "x" } } },
                },
            })
        end)

        it("supports explicit named, method, and constructor calls", function()
            assert_expression_ast("make<|integer|>{item = x}", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeInteger" } },
                args = {
                    _tag = "Ast.ArgsNamedFunc",
                    fields = { { name = "item", exp = { var = { name = "x" } } } },
                },
            })
            assert_expression_ast("object:map<|string|>(x)", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = { _tag = "Ast.ArgsMethod", method = "map" },
            })
            assert_expression_ast("object:map<|string|>{item = x}", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = { _tag = "Ast.ArgsNamedMethod", method = "map" },
            })
            assert_expression_ast("Pair<|integer, string|>.new(1, 'one')", {
                _tag = "Ast.ExpCall",
                exp = { var = {
                    _tag = "Ast.VarDot",
                    name = "new",
                    exp = {
                        _nominal_typeargs = {
                            { _tag = "Ast.TypeInteger" },
                            { _tag = "Ast.TypeString" },
                        },
                    },
                } },
                typeargs = {},
                args = { _tag = "Ast.ArgsFunc" },
            })
            assert_expression_ast("library.Pair<|T|>.from<|U|>{item = x}", {
                _tag = "Ast.ExpCall",
                exp = { var = {
                    _tag = "Ast.VarDot",
                    name = "from",
                    exp = {
                        _nominal_typeargs = {
                            { _tag = "Ast.TypeName", name = "T" },
                        },
                    },
                } },
                typeargs = {
                    { _tag = "Ast.TypeName", name = "U" },
                },
                args = { _tag = "Ast.ArgsNamedFunc" },
            })
        end)

        it("keeps bare strings positional after the factored generic prefix",
        function()
            assert_expression_ast("make<|string|> 'item'", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = {
                    _tag = "Ast.ArgsFunc",
                    args = { { _tag = "Ast.ExpString", value = "item" } },
                },
            })
            assert_expression_ast("object:map<|string|> 'item'", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = {
                    _tag = "Ast.ArgsMethod",
                    method = "map",
                    args = { { _tag = "Ast.ExpString", value = "item" } },
                },
            })
        end)

        it("keeps adjacent generic closes on aggregate-owner selections",
        function()
            assert_expression_ast("Box<|Outer<|Inner<|T|>|>|>.make()", {
                _tag = "Ast.ExpCall",
                exp = { var = {
                    _tag = "Ast.VarDot",
                    name = "make",
                    exp = {
                        _nominal_typeargs = { {
                            _tag = "Ast.TypeName",
                            name = "Outer",
                            typeargs = { {
                                _tag = "Ast.TypeName",
                                name = "Inner",
                                typeargs = { {
                                    _tag = "Ast.TypeName",
                                    name = "T",
                                } },
                            } },
                        } },
                    },
                } },
                typeargs = {},
                args = { _tag = "Ast.ArgsFunc" },
            })
        end)

        it("prescans dense angles without changing generic suffixes", function()
            local angles = string.rep("<", 40)
            local source = util.render([==[
                local comment_padding = 1 -- $ANGLES
                local short_padding = "$ANGLES"
                local long_padding = [=[$ANGLES]=]

                local function probe()
                    local call = f<|function (integer): (Outer<|Inner<|T|>|>)|>(x)
                    local member = Box<|Outer<|Inner<|T|>|>|>.make()
                    local method = object:map<|Outer<|Inner<|T|>|>|>(x)
                    local comparison = a < b > c
                    local commented_call = f<|T|> -- call after comment
                        (x)
                end
            ]==], { ANGLES = angles })
            local program = assert_parses_successfuly(source)
            local stats = program[#program].block.stats

            assert.are.equal("Ast.TypeFunction",
                stats[1].exps[1].typeargs[1]._tag)
            assert.are.equal("Outer",
                stats[2].exps[1].exp.var.exp._nominal_typeargs[1].name)
            assert.are.equal("Outer", stats[3].exps[1].typeargs[1].name)
            assert.are.equal("map", stats[3].exps[1].args.method)
            assert.are.equal(">", stats[4].exps[1].op)
            assert.are.equal("<", stats[4].exps[1].lhs.op)
            assert.are.equal("Ast.ExpCall", stats[5].exps[1]._tag)
            assert.are.equal("T", stats[5].exps[1].typeargs[1].name)
        end)

        it("preserves lexical failures at a committed expression start",
        function()
            local source = "local function probe()\n" ..
                " local text = [=[" .. string.rep("<", 40) .. "\nend\n"
            local program, err = parser.parse("dense-angles.titan", source)
            assert.falsy(program)
            assert.are.equal("UnclosedLongString", err.label)
            assert.are.same({
                filename = "dense-angles.titan",
                line = 2,
                col = 18,
            }, err.loc)
        end)

        it("does not treat callable arguments as a bound-method specialization",
        function()
            local parsed = parser.parse(
                "(parser_spec)", "local f = object:map<integer>")
            assert.is_false(parsed)
        end)

        it("gives a complete generic call suffix priority over comparisons",
        function()
            assert_expression_ast("a < b > c", {
                _tag = "Ast.ExpBinop",
                op = ">",
                lhs = { _tag = "Ast.ExpBinop", op = "<" },
            })
            assert_expression_ast("a <| b |> (c)", {
                _tag = "Ast.ExpCall",
                exp = { var = { name = "a" } },
                typeargs = { { _tag = "Ast.TypeName", name = "b" } },
            })
            assert_expression_ast("(a < b) > (c)", {
                _tag = "Ast.ExpBinop",
                op = ">",
                lhs = { _tag = "Ast.ExpBinop", op = "<" },
            })
            assert_expression_ast("a >= b", {
                _tag = "Ast.ExpBinop", op = ">=",
            })
            assert_expression_ast("a >> b", {
                _tag = "Ast.ExpBinop", op = ">>",
            })
        end)
    end)

    it("keeps constructor arguments positional when parenthesized", function()
        local function positional_constructor(fields)
            return { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = {
                    { _tag = "Ast.ExpInitList", fields = fields } } } }
        end

        assert_expression_ast([[ f({}) ]], positional_constructor({}))
        assert_expression_ast([[ f({ x = 1 }) ]], positional_constructor({
            { name = "x", exp = { value = 1 } },
        }))
        assert_expression_ast([[ f({ 1, 2 }) ]], positional_constructor({
            { name = nil, exp = { value = 1 } },
            { name = nil, exp = { value = 2 } },
        }))
        assert_expression_ast([[ f({ [k] = v }) ]], positional_constructor({
            { name = { var = { name = "k" } },
              exp = { var = { name = "v" } } },
        }))
    end)

    it("rejects non-named and mixed entries in bare brace calls", function()
        assert_expression_syntax_error([[ f { 1 } ]], "NameNamedArg")
        assert_expression_syntax_error([[ f { [k] = v } ]], "NameNamedArg")
        assert_expression_syntax_error([[ f { ... } ]], "NameNamedArg")
        assert_expression_syntax_error([[ f { x = 1, 2 } ]], "NameNamedArg")
        assert_expression_syntax_error(
            [[ f { x = 1; [k] = v } ]], "NameNamedArg")
    end)

    it("reports named-call-specific punctuation errors", function()
        assert_expression_syntax_error([[ f { = 1 } ]], "NameNamedArg")
        assert_expression_syntax_error([[ f { x } ]], "AssignNamedArg")
        assert_expression_syntax_error([[ f { x = } ]], "ExpNamedArg")
        assert_expression_syntax_error([[ f { x = 1,, } ]], "NameNamedArg")
        assert_expression_syntax_error([[ f { x = 1 ]], "RCurlyNamedArgs")
        assert_program_syntax_error([[
            function unfinished()
                f { x = 1,
        ]], "RCurlyNamedArgs")
    end)

    it("continues folding suffixes after a named call", function()
        assert_expression_ast([[ f{x = 1}.field ]], {
            _tag = "Ast.ExpVar",
            var = { _tag = "Ast.VarDot", name = "field",
                exp = { _tag = "Ast.ExpCall",
                    args = { _tag = "Ast.ArgsNamedFunc" } } },
        })
    end)

    it("parses a bound method reference (obj:m with no argument list)", function()
        -- `o:m` with no `()` is a bound-method-reference expression, distinct
        -- from a method call. A real call (`o:m()`) still parses as ExpCall.
        assert_expression_ast([[ o:m ]],
            { _tag = "Ast.ExpMethodRef", name = "m",
              exp = { _tag = "Ast.ExpVar",
                      var = { _tag = "Ast.VarName", name = "o" } } })

        -- in an arithmetic context the ref is the left operand
        assert_expression_ast([[ o:m + 1 ]],
            { _tag = "Ast.ExpBinop", op = "+",
              lhs = { _tag = "Ast.ExpMethodRef", name = "m" } })
    end)

    it('preserves non-call prefix statements for semantic rejection', function()

        local p=assert_parses_successfuly("function f() x; 1; (f()); x.m end")
        for _,stat in ipairs(p[1].block.stats) do assert.equal("Ast.StatCall",stat._tag) end
        assert.equal("Ast.ExpAdjust",p[1].block.stats[3].callexp._tag)
    end)

    it("can parse import", function ()
        assert_program_ast([[ local foo = import "module.foo" ]], {
            { _tag = "Ast.TopLevelImport", localname = "foo",
              modname = "module.foo", source_required = false },
        })
    end)

    it("strips the .titan explicit-source marker from import names",
       function()
        assert_program_ast([[ local foo = import "module.foo.titan" ]], {
            { _tag = "Ast.TopLevelImport", localname = "foo",
              modname = "module.foo", source_required = true },
        })
        assert_program_ast([[ local uv = import "uv.titan" ]], {
            { _tag = "Ast.TopLevelImport", localname = "uv",
              modname = "titan.uv", source_required = true },
        })
        assert_program_ast([[ local uv = import "titan.uv.titan" ]], {
            { _tag = "Ast.TopLevelImport", localname = "uv",
              modname = "titan.uv", source_required = true },
        })
        assert_program_ast([[ local websocket = import "websocket.titan" ]], {
            { _tag = "Ast.TopLevelImport", localname = "websocket",
              modname = "titan.websocket", source_required = true },
        })
        assert_program_ast([[ local foo = import "foo.titan.titan" ]], {
            { _tag = "Ast.TopLevelImport", localname = "foo",
              modname = "foo.titan", source_required = true },
        })
    end)

    it("desugars standard-library short imports to qualified modules",
       function()
        local names = {
            "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
            "url", "http", "websocket", "os", "path", "peg", "string", "test", "sqlite3", "json", "protobuf", "transfer",
        }
        for _, name in ipairs(names) do
            assert_program_ast(
                'local library = import "' .. name .. '"', {
                    {
                        _tag = "Ast.TopLevelImport",
                        localname = "library",
                        modname = "titan." .. name,
                        source_required = false,
                    },
                })
            assert_program_ast(
                'local library = import "titan.' .. name .. '"', {
                    {
                        _tag = "Ast.TopLevelImport",
                        localname = "library",
                        modname = "titan." .. name,
                        source_required = false,
                    },
                })
        end
    end)

    it("can parse multiple assignment", function ()
        assert_statements_ast([[
            x, foo.bar, z[2] = 20, 30, "foo"
        ]],{ {
            vars = {
                { name = "x" },
                { _tag = "Ast.VarDot" },
                { _tag = "Ast.VarBracket" }
            }
        }})
    end)

    it("expects lvalue after comma in lhs of assignment", function()
        assert_statements_syntax_error([[
            x, = 20
        ]], "ExpVarList")
    end)

    it("can parse references to module members", function ()
        assert_statements_ast([[
            foo.bar = 50
            print(foo.bar)
            foo.write(a, b, c)
        ]], {
            { vars = {{
                _tag = "Ast.VarDot",
                exp = { _tag = "Ast.ExpVar",
                  var = { _tag = "Ast.VarName", name = "foo" }
                },
                name = "bar" }} },
            { callexp = { args = { args = { { var = {
                _tag = "Ast.VarDot",
                exp = { _tag = "Ast.ExpVar",
                  var = { _tag = "Ast.VarName", name = "foo" }
                },
              name = "bar" } } } } } },
            { callexp = {
                exp = { var = {
                    _tag = "Ast.VarDot",
                    exp = { _tag = "Ast.ExpVar",
                      var = { _tag = "Ast.VarName", name = "foo" }
                    },
                    name = "write" } } } }
        })
    end)

    it("can parse record declarations", function()
        assert_program_ast([[
            record Point
                x: float
                y: float
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              name = "Point",
              fields = {
                { name = "x", type = { _tag = "Ast.TypeFloat" } },
                { name = "y", type = { _tag = "Ast.TypeFloat" } } } },
        })

        assert_program_ast([[
            record List
                p: {Point}
                next: List
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              name = "List",
              fields = {
                { name = "p",
                  type = { subtype = { name = "Point" } } },
                { name = "next", type = { name = "List" } } } },
        })

        assert_program_ast([[
            local record Box
                local hidden: integer
                visible: integer
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              islocal = true,
              name = "Box",
              fields = {
                { name = "hidden", islocal = true,
                  type = { _tag = "Ast.TypeInteger" } },
                { name = "visible",
                  type = { _tag = "Ast.TypeInteger" } } } },
        })

        assert_program_ast([[
            record Owners
                handle: (owned *Handle)?
                local bytes: (owned Byte[])?
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              name = "Owners",
              fields = {
                { name = "handle", type = {
                    _tag = "Ast.TypeOption",
                    basetype = {
                        _tag = "Ast.TypeOwned",
                        subtype = { _tag = "Ast.TypeCPointer" },
                    },
                } },
                { name = "bytes", islocal = true, type = {
                    _tag = "Ast.TypeOption",
                    basetype = {
                        _tag = "Ast.TypeOwned",
                        subtype = { _tag = "Ast.TypeCArray" },
                    },
                } } } },
        })

        assert_program_ast([[
            record Snapshot
                const id: integer
                local const hidden: string
                const next: Snapshot?
                local const payload: value?
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              name = "Snapshot",
              fields = {
                { name = "id", isconst = true, islocal = nil,
                  type = { _tag = "Ast.TypeInteger" } },
                { name = "hidden", isconst = true, islocal = true,
                  type = { _tag = "Ast.TypeString" } },
                { name = "next", isconst = true,
                  type = { _tag = "Ast.TypeOption" } },
                { name = "payload", isconst = true, islocal = true,
                  type = { _tag = "Ast.TypeOption" } },
              } },
        })
    end)

    it("parses unions and synthesizes adjacent positional constructors",
    function()
        local source = [[
            union Message
                quit();
                move(Message)
                local nil_payload(nil);
            end
        ]]
        assert_program_ast(source, {
            {
                _tag = "Ast.TopLevelUnion",
                islocal = false,
                name = "Message",
                variants = {
                    {
                        _tag = "Ast.UnionVariant",
                        name = "quit",
                        parts = {},
                    },
                    {
                        _tag = "Ast.UnionVariant",
                        name = "move",
                        parts = {{ name = "value", type = {
                            _tag = "Ast.TypeName", name = "Message",
                        } }},
                    },
                    {
                        _tag = "Ast.UnionVariant",
                        islocal = true,
                        name = "nil_payload",
                        parts = {{ name = "value", type = { _tag = "Ast.TypeNil" } }},
                    },
                },
            },
            {
                _tag = "Ast.TopLevelStatic",
                class = "Message",
                name = "quit",
                params = {},
                islocal = false,
                _union_constructor = true,
                block = {
                    stats = {
                        {
                            _tag = "Ast.StatReturn",
                            exps = {
                                {
                                    _tag = "Ast.ExpUnionInit",
                                    owner = "Message",
                                    values = {},
                                },
                            },
                        },
                    },
                },
            },
            {
                _tag = "Ast.TopLevelStatic",
                class = "Message",
                name = "move",
                params = {
                    {
                        _tag = "Ast.Decl",
                        name = "value",
                        type = {
                            _tag = "Ast.TypeName",
                            name = "Message",
                        },
                    },
                },
                islocal = false,
                _union_constructor = true,
                block = {
                    stats = {
                        {
                            exps = {
                                {
                                    _tag = "Ast.ExpUnionInit",
                                    owner = "Message",
                                    values = {{
                                        _tag = "Ast.ExpVar",
                                        var = {
                                            _tag = "Ast.VarName",
                                            name = "value",
                                        },
                                    }},
                                },
                            },
                        },
                    },
                },
            },
            {
                _tag = "Ast.TopLevelStatic",
                class = "Message",
                name = "nil_payload",
                params = {
                    {
                        _tag = "Ast.Decl",
                        type = { _tag = "Ast.TypeNil" },
                    },
                },
                islocal = true,
                _union_constructor = true,
            },
        })

        local parsed = assert_parses_successfuly(source)
        assert.are.equal(4, #parsed)
        for i = 1, 3 do
            local constructor = parsed[i + 1]
            assert.is_true(constructor._union_constructor)
            assert.are.equal(parsed[1].variants[i], constructor._union_variant)
        end
    end)

    it("parses named union parts and synthesizes matching constructor arguments", function()
        local tree = assert_parses_successfuly([[
            union Packet<|T|>
                data(item: T, end: integer, optional: string?)
                empty()
            end
        ]])
        local parts = tree[1].variants[1].parts
        assert.are.equal(3, #parts)
        assert_is_subset({
            { name = "item", type = { _tag = "Ast.TypeName", name = "T" } },
            { name = "end", type = { _tag = "Ast.TypeInteger" } },
            { name = "optional", type = { _tag = "Ast.TypeOption" } },
        }, parts)
        local constructor = tree[2]
        assert.are.equal(3, #constructor.params)
        local values = constructor.block.stats[1].exps[1].values
        for i, part in ipairs(parts) do
            assert.are.equal(part.name, constructor.params[i].name)
            assert.are.equal(part.type, constructor.params[i].type)
            assert.are.equal(part.name, values[i].var.name)
            assert.are.equal(part._name_loc, constructor.params[i]._name_loc)
        end
        assert.are.equal(0, #tree[1].variants[2].parts)
    end)

    it("distinguishes named parts from every single-type payload prefix", function()
        local tree = assert_parses_successfuly([[
            union Alternatives
                named(nil: nil, function: function(integer): (integer), local: string)
                scalar(integer)
                nil_value(nil)
                nominal(Item)
                qualified(module.Item)
                array({integer})
                map({string: integer})
                grouped((integer))
                callable(function(integer, string): (integer, string))
                c_pointer(foreign *int)
                owned_pointer(owned *int)
                optional(string?)
                local()
                end()
                local local()
            end
        ]])
        local variants = tree[1].variants
        assert.are.equal(15, #variants)
        assert.are.equal("nil", variants[1].parts[1].name)
        assert.are.equal("function", variants[1].parts[2].name)
        assert.are.equal("local", variants[1].parts[3].name)
        for i = 2, 12 do
            assert.are.equal(1, #variants[i].parts)
            assert.are.equal("value", variants[i].parts[1].name)
        end
        assert.are.equal("local", variants[13].name)
        assert.are.equal("end", variants[14].name)
        assert.is_true(variants[15].islocal)
    end)

    it("labels malformed union payload lists and forbids flexible tails", function()
        local cases = {
            { "item", "LParenVariant" },
            { "item(a:)", "TypeUnionVariant" },
            { "item(a: integer,)", "NameVariantPayload" },
            { "item(a: integer, b string)", "ColonVariantPayload" },
            { "item(a: integer, b:)", "TypeUnionVariant" },
            { "item(a: integer", "RParenVariant" },
            { "item(integer", "RParenVariantPayload" },
            { "item(integer, string)", "RParenVariantPayload" },
            { "item(a: integer; b: string)", "RParenVariant" },
            { "item(...: integer)", "TypeUnionVariant" },
            { "item(a: integer, ...: string)", "NameVariantPayload" },
        }
        for _, test in ipairs(cases) do
            assert_program_syntax_error("union U " .. test[1] .. " end", test[2])
        end
    end)

    it("makes every constructor of a local union local", function()
        local ast = assert_parses_successfuly([[
            local union Hidden
                empty()
                payload(integer)
            end
        ]])
        assert.are.equal(3, #ast)
        assert.is_true(ast[1].islocal)
        assert.is_true(ast[2].islocal)
        assert.is_true(ast[3].islocal)
    end)

    it("keeps union declarations top-level and case statements block-local",
    function()
        local nested_union = parser.parse("(parser_spec)", [[
            function f(): nil
                union Nested
                    item
                end
            end
        ]])
        assert.falsy(nested_union)

        local top_case = parser.parse("(parser_spec)", [[
            case item_value
            when item() then
            end
        ]])
        assert.falsy(top_case)
    end)

    it("parses one or several ordered, bodyless interface methods", function()
        assert_program_ast([[
            interface Ping
                function ping()
            end
        ]], {
            {
                _tag = "Ast.TopLevelInterface",
                name = "Ping",
                methods = {
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "ping",
                        params = {},
                        rettypes = {},
                        flexrettype = nil,
                    },
                },
            },
        })

        local source = table.concat({
            "interface Reader",
            "function read(): string?",
            "function flush()",
            "function read_until(delimiter: string, chop: boolean?): (string, integer)",
            "function scan(prefix: string, ...: integer): (boolean, ...: value)",
            "end",
        }, "\n")
        local parsed = assert_parses_successfuly(source)

        assert_is_subset({
            {
                _tag = "Ast.TopLevelInterface",
                name = "Reader",
                methods = {
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "read",
                        params = {},
                        rettypes = {
                            {
                                _tag = "Ast.TypeOption",
                                basetype = { _tag = "Ast.TypeString" },
                            },
                        },
                        flexrettype = nil,
                    },
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "flush",
                        params = {},
                        rettypes = {},
                        flexrettype = nil,
                    },
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "read_until",
                        params = {
                            {
                                _tag = "Ast.Decl",
                                name = "delimiter",
                                type = { _tag = "Ast.TypeString" },
                            },
                            {
                                _tag = "Ast.Decl",
                                name = "chop",
                                type = {
                                    _tag = "Ast.TypeOption",
                                    basetype = { _tag = "Ast.TypeBoolean" },
                                },
                            },
                        },
                        rettypes = {
                            { _tag = "Ast.TypeString" },
                            { _tag = "Ast.TypeInteger" },
                        },
                        flexrettype = nil,
                    },
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "scan",
                        params = {
                            {
                                _tag = "Ast.Decl",
                                name = "prefix",
                                type = { _tag = "Ast.TypeString" },
                            },
                            {
                                _tag = "Ast.Decl",
                                name = nil,
                                type = { _tag = "Ast.TypeInteger" },
                            },
                        },
                        rettypes = {
                            { _tag = "Ast.TypeBoolean" },
                        },
                        flexrettype = { _tag = "Ast.TypeValue" },
                    },
                },
            },
        }, parsed)

        local interface = parsed[1]
        assert.are.same({
            filename = "(parser_spec)",
            line = 1,
            col = 1,
        }, interface.loc)
        assert.are.same({
            filename = "(parser_spec)",
            line = 2,
            col = 1,
        }, interface.methods[1].loc)
        assert.are.same({
            filename = "(parser_spec)",
            line = 2,
            col = 18,
        }, interface.methods[1].rettypes[1].loc)
        assert.are.same({
            filename = "(parser_spec)",
            line = 4,
            col = 21,
        }, interface.methods[3].params[1].loc)
        assert.are.same({
            filename = "(parser_spec)",
            line = 5,
            col = 31,
        }, interface.methods[4].params[2].loc)
    end)

    it("preserves duplicate interface method declarations for the checker",
    function()
        local parsed = assert_parses_successfuly([[
            interface Duplicate
                function same()
                function same(item: integer): nil
            end
        ]])
        assert.are.equal(2, #parsed[1].methods)
        assert.are.equal("same", parsed[1].methods[1].name)
        assert.are.equal("same", parsed[1].methods[2].name)
    end)

    it("parses field-only and mixed interfaces in source order", function()
        local parsed = assert_parses_successfuly([[
            interface Snapshot
                id: integer
                function render(prefix: string): string
                label: string?
            end

            interface Position
                x: float
                y: float
            end
        ]])

        assert_is_subset({
            {
                _tag = "Ast.TopLevelInterface",
                fields = {
                    { _tag = "Ast.Decl", name = "id", isconst = true,
                        type = { _tag = "Ast.TypeInteger" } },
                    { _tag = "Ast.Decl", name = "label", isconst = true,
                        type = { _tag = "Ast.TypeOption" } },
                },
                methods = {
                    { _tag = "Ast.InterfaceMethod", name = "render" },
                },
                members = {
                    { _tag = "Ast.Decl", name = "id" },
                    { _tag = "Ast.InterfaceMethod", name = "render" },
                    { _tag = "Ast.Decl", name = "label" },
                },
            },
            {
                _tag = "Ast.TopLevelInterface",
                fields = {
                    { name = "x", isconst = true },
                    { name = "y", isconst = true },
                },
                methods = {},
            },
        }, parsed)
    end)

    it("does not apply the parameter/expression list cap to interface methods",
    function()
        local source = { "interface Many" }
        local method_count = 140
        for i = 1, method_count do
            source[#source + 1] = string.format("function method_%d()", i)
        end
        source[#source + 1] = "end"

        local parsed = assert_parses_successfuly(table.concat(source, "\n"))
        assert.are.equal(method_count, #parsed[1].methods)
        assert.are.equal("method_1", parsed[1].methods[1].name)
        assert.are.equal(
            "method_" .. method_count,
            parsed[1].methods[method_count].name)
    end)

    it('rejects invalid interface declaration and member forms', function()

        assert_program_syntax_error("local interface I end","LocalInterface")
        assert_program_syntax_error("interface I function f() end end","fail")
        assert_program_syntax_error("interface I local x: integer end","EndInterface")
        assert_parses_successfuly("interface Empty end")
        assert_parses_successfuly("interface I function: integer end: string end")
    end)

    describe("can parse generic declarations", function()
        it("retains owner and callable binders in their source scopes",
        function()
            local program = assert_parses_successfuly([[
                record Pair<|T, U: api.Show<|T|>|>
                    first: T
                    second: U
                end

                union Result<|T, E|>
                    ok(T)
                    error(E)
                end

                interface Stack<|E|>
                    function push<|R: Stack<|E|>|>(item: E): R
                end

                function id<|T|>(x: T): T return x end
                function Pair:map<|V|>(f: function (T): (V)): Pair<|V, U|>
                    return nil
                end
                function Pair.make<|V|>(item: V): Pair<|V, V|>
                    return nil
                end
            ]])

            assert_is_subset({
                {
                    _tag = "Ast.TopLevelRecord",
                    name = "Pair",
                    typeparams = {
                        { _tag = "Ast.TypeParam", name = "T", constraint = nil },
                        {
                            _tag = "Ast.TypeParam",
                            name = "U",
                            constraint = {
                                _tag = "Ast.TypeQualName",
                                module = "api",
                                name = "Show",
                                typeargs = {
                                    { _tag = "Ast.TypeName", name = "T", typeargs = {} },
                                },
                            },
                        },
                    },
                    fields = {
                        { name = "first", type = {
                            _tag = "Ast.TypeName", name = "T", typeargs = {} } },
                        { name = "second", type = {
                            _tag = "Ast.TypeName", name = "U", typeargs = {} } },
                    },
                },
                {
                    _tag = "Ast.TopLevelStatic",
                    class = "Pair",
                    name = "new",
                    typeparams = {},
                    rettypes = {
                        {
                            _tag = "Ast.TypeName",
                            name = "Pair",
                            typeargs = {
                                { _tag = "Ast.TypeName", name = "T", typeargs = {} },
                                { _tag = "Ast.TypeName", name = "U", typeargs = {} },
                            },
                        },
                    },
                },
                {
                    _tag = "Ast.TopLevelUnion",
                    name = "Result",
                    typeparams = {
                        { name = "T", constraint = nil },
                        { name = "E", constraint = nil },
                    },
                },
                {
                    _tag = "Ast.TopLevelStatic",
                    class = "Result",
                    name = "ok",
                    typeparams = {},
                    rettypes = { {
                        name = "Result",
                        typeargs = {
                            { name = "T", typeargs = {} },
                            { name = "E", typeargs = {} },
                        },
                    } },
                },
                {
                    _tag = "Ast.TopLevelStatic",
                    class = "Result",
                    name = "error",
                    typeparams = {},
                },
                {
                    _tag = "Ast.TopLevelInterface",
                    name = "Stack",
                    typeparams = { { name = "E", constraint = nil } },
                    methods = { {
                        _tag = "Ast.InterfaceMethod",
                        name = "push",
                        typeparams = { {
                            name = "R",
                            constraint = {
                                _tag = "Ast.TypeName",
                                name = "Stack",
                                typeargs = { { name = "E", typeargs = {} } },
                            },
                        } },
                    } },
                },
                {
                    _tag = "Ast.TopLevelFunc",
                    name = "id",
                    typeparams = { { name = "T", constraint = nil } },
                },
                {
                    _tag = "Ast.TopLevelMethod",
                    class = "Pair",
                    name = "map",
                    typeparams = { { name = "V", constraint = nil } },
                },
                {
                    _tag = "Ast.TopLevelStatic",
                    class = "Pair",
                    name = "make",
                    typeparams = { { name = "V", constraint = nil } },
                },
            }, program)

            assert.are.equal(9, #program)
        end)

        it("records empty binder lists on existing declarations", function()
            local program = assert_parses_successfuly([[
                record Plain item: integer end
                union Maybe none() end
                interface Ping function ping() end
                function plain(): nil end
                function Plain:method(): nil end
                function Plain.static(): nil end
            ]])
            assert.are.same({}, program[1].typeparams)
            assert.are.same({}, program[2].typeparams)
            assert.are.same({}, program[3].typeparams)
            assert.are.same({}, program[4].typeparams)
            assert.are.same({}, program[5].typeparams)
            assert.are.same({}, program[5].methods[1].typeparams)
            assert.are.same({}, program[6].typeparams)
            assert.are.same({}, program[7].typeparams)
            assert.are.same({}, program[8].typeparams)
        end)
    end)

    it("can parse public and local type aliases", function()
        assert_program_ast([[
            type Count = integer
            local type Errors = { uv.Error }
        ]], {
            {
                _tag = "Ast.TopLevelTypeAlias",
                islocal = false,
                name = "Count",
                type = { _tag = "Ast.TypeInteger" },
            },
            {
                _tag = "Ast.TopLevelTypeAlias",
                islocal = true,
                name = "Errors",
                type = {
                    _tag = "Ast.TypeArray",
                    subtype = {
                        _tag = "Ast.TypeQualName",
                        module = "uv",
                        name = "Error",
                    },
                },
            },
        })
    end)

    it("can parse the record field optional separator", function()
        local ast = {{ fields = { { name = "x" }, { name = "y" } } }}

        assert_program_ast([[
            record Point x: float y: float end
        ]], ast)

        assert_program_ast([[
            record Point x: float; y: float end
        ]], ast)

        assert_program_ast([[
            record Point x: float y: float; end
        ]], ast)

        assert_program_ast([[
            record Point x: float; y: float; end
        ]], ast)

        assert_program_ast([[
            record A
            end
        ]], {{ fields = { } }})
    end)

    it("can parse record constructors", function()
        assert_expression_ast([[ { x = 1.1, y = 2.2 } ]],
            { _tag = "Ast.ExpInitList", fields = {
                { name = "x", exp = { value = 1.1 } },
                { name = "y", exp = { value = 2.2 } } }})

        assert_expression_ast([[ { p = {}, next = nil } ]],
            { _tag = "Ast.ExpInitList", fields = {
                { name = "p",    exp = { _tag = "Ast.ExpInitList" } },
                { name = "next", exp = { _tag = "Ast.ExpNil" } } }})

        assert_expression_ast([[ Point.new(1.1, 2.2) ]],
            { _tag = "Ast.ExpCall",
                args = { args = {
                  { value = 1.1 },
                  { value = 2.2 } } },
                exp = { var = {
                    _tag = "Ast.VarDot",
                    exp = { var = { name = "Point" } },
                    name = "new" } } })

        assert_expression_ast([[ List.new({}, nil) ]],
            { _tag = "Ast.ExpCall",
                args = { args = {
                  { _tag = "Ast.ExpInitList" },
                  { _tag = "Ast.ExpNil" } } },
                exp = { var = {
                    _tag = "Ast.VarDot",
                    exp = { var = { name = "List" } },
                    name = "new" } } })
    end)

    it("can parse record field access", function()
        assert_expression_ast([[ p.x ]],
            { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarDot",
                name = "x",
                exp = { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarName",
                    name = "p" } } } })

        assert_expression_ast([[ a.b[1].c ]],
            { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarDot",
                name = "c",
                exp = { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarBracket",
                    exp2 = { value = 1 },
                    exp1 = { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarDot",
                        name = "b",
                        exp = { _tag = "Ast.ExpVar", var = { _tag = "Ast.VarName",
                            name = "a" } } } } } } } })
    end)

    it('can parse cast and type-test expressions', function()

        assert_expression_ast("2 + foo as integer",{op="+",rhs={_tag="Ast.ExpCast"}})
        assert_expression_ast("-foo is integer",{_tag="Ast.ExpIs",exp={op="-"}})
        assert_expression_ast("foo ^ 2 is integer",{_tag="Ast.ExpIs",exp={op="^"}})
        assert_expression_ast("foo ^ 2 as integer",{_tag="Ast.ExpCast",exp={op="^"}})
        assert_expression_ast("(foo as value) is integer",{_tag="Ast.ExpIs",
            exp={_tag="Ast.ExpCast"}})
        assert_expression_ast("foo is function(integer): integer",{_tag="Ast.ExpIs",
            target={_tag="Ast.TypeFunction"}})
        assert_expression_ast("#... as value",{_tag="Ast.ExpCast",
            exp={_tag="Ast.ExpDotsLen"}})
        for _,exp in ipairs({"x as T as U","x is T is U","x as T is U"}) do
            assert_expression_syntax_error(exp,"EndFunc")
        end
    end)

    it('retains every assignment candidate and parenthesis boundary for the checker', function()

        local p=assert_parses_successfuly("function f() (x), f(), 1 = a,b,c end")
        local stat=p[1].block.stats[1]
        assert.is_true(stat._parsed_candidates)
        assert.is_true(stat.vars[1]._parenthesized)
        assert.equal("Ast.ExpCall",stat.vars[2]._tag)
        assert.equal("Ast.ExpInteger",stat.vars[3]._tag)
    end)

    it('accepts primitive type words as ordinary names', function()

        assert_parses_successfuly([[
            function integer(boolean: integer): integer return boolean end
            local float = 1
            record value string: string end
            function f() local boolean = true end
        ]])
    end)

    it('leaves contextual primitive term-name resolution to the checker', function()

        assert_expression_ast("integer.new(1)",{_tag="Ast.ExpCall",
            exp={var={_tag="Ast.VarDot",exp={var={name="integer"}}}}})
    end)

    it('reports source locations for union and case labels', function()

        local p=assert(parser.parse("labels.titan",[[union Choice some(integer) end
function f(x: Choice) case x when some(v) then return end end]]))
        assert.same({filename="labels.titan",line=1,col=14},p[1].variants[1]._name_loc)
        local arm=p[3].block.stats[1].arms[1]
        assert.same({filename="labels.titan",line=2,col=35},arm._name_loc)
        assert.same({filename="labels.titan",line=2,col=40},arm.bindings[1]._name_loc)
    end)

    describe("reports focused generic syntax errors", function()
        it("labels malformed declaration binders and type applications",
        function()
            assert_program_syntax_error("record Empty<|> end", "NameTypeParam")
            assert_program_syntax_error(
                "record Trailing<|T,|> item: T end", "NameTypeParam")
            assert_program_syntax_error(
                "record Missing<|T:|> item: T end", "TypeParamConstraint")
            assert_program_syntax_error(
                "record Unclosed<|T item: T end", "RAngleTypeParams")

            assert_type_syntax_error("Pair<|>", "TypeArgument")
            assert_type_syntax_error("Pair<|T,|>", "TypeArgument")
            assert_type_syntax_error("Pair<|T", "RAngleTypeArgs")
        end)

        it("rejects binders on foreign functions, lambdas, and aliases",
        function()
            assert_program_syntax_error([[
                foreign function callback<|T|>(item: T): T return item end
            ]], "GenericForeignFunc")
            assert_program_syntax_error([[
                function outer(): nil
                    local callback = function<|T|>(item: T): T return item end
                end
            ]], "GenericLambda")
            assert_program_syntax_error(
                "type Identity<|T|> = T", "GenericTypeAlias")
        end)

        it('commits an explicit generic suffix without probing comparisons', function()

        assert_expression_syntax_error("f<|T,|>(x)","TypeArgument")
        assert_expression_syntax_error("f<|T(x)","RAngleTypeArgs")
        assert_expression_ast("a < b > c",{op=">",lhs={op="<"}})
    end)

        it("registers every lexer and parser failure label", function()
            local labels = {}
            for _, filename in ipairs({
                "titan-compiler/lexer.lua",
                "titan-compiler/parser.lua",
            }) do
                local file = assert(io.open(filename, "r"))
                local source = file:read("*a")
                file:close()

                for label in source:gmatch("%^([%a_][%w_]*)") do
                    labels[label] = true
                end
                for label in source:gmatch("%%{([%a_][%w_]*)}") do
                    labels[label] = true
                end
                for label in source:gmatch('T%("([%a_][%w_]*)"%)') do
                    labels[label] = true
                end
            end

            for label in pairs(labels) do
                assert.truthy(syntax_errors.errors[label],
                    "missing syntax_errors entry for " .. label)
            end
        end)
    end)

    it('uses specific error labels for some errors', function()

        local cases={
            {"function () end","NameFunc"},
            {"function R:() end","NameMethod"},
            {"function f(x) end","ParamSemicolon"},
            {"function f(: integer) end","RParPList"},
            {"function f(): , end","TypeFunc"},
            {"function f() return 1","EndFunc"},
            {"x =","ExpVarDec"},
            {"type Alias integer","AssignTypeAlias"},
            {"type Alias =","TypeTypeAlias"},
            {"record","NameRecord"},
            {"record R x: integer","EndRecord"},
            {"union U A(integer","RParenVariantPayload"},
            {"foreign function f(x) end","ParamSemicolon"},
            {"foreign type Callback = function(int) int","ForeignReturnColon"},
            {"local x: {integer","RCurlyType"},
            {"local x: {integer:}","TypeType"},
            {"function f() local = 1 end","DeclLocal"},
            {"function f() f(1, ) end","ExpExpList"},
            {"function f() if true return end end","ThenIf"},
            {"function f() while true return end end","DoWhile"},
            {"function f() for x=1 do end end","CommaFor"},
        }
        for _,case in ipairs(cases) do assert_program_syntax_error(case[1],case[2]) end
    end)

    describe("can parse variadic parameters", function()
        it("as the last parameter of a top-level function", function()
            assert_program_ast([[
                function foo(a: integer, ...: integer): nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    name = "foo",
                    params = {
                        { _tag = "Ast.Decl", name = "a" },
                        { _tag = "Ast.Decl", name = nil,
                          type = { _tag = "Ast.TypeInteger" } },
                    } },
            })
        end)

        it("as the sole parameter of a top-level function", function()
            assert_program_ast([[
                function foo(...: string): nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    name = "foo",
                    params = {
                        { _tag = "Ast.Decl", name = nil,
                          type = { _tag = "Ast.TypeString" } },
                    } },
            })
        end)

        it("as the last parameter of a method", function()
            assert_program_ast([[
                function Record:m(a: integer, ...: integer): nil
                end
            ]], {
                { _tag = "Ast.TopLevelMethod",
                    class = "Record",
                    name = "m",
                    params = {
                        { _tag = "Ast.Decl", name = "a" },
                        { _tag = "Ast.Decl", name = nil,
                          type = { _tag = "Ast.TypeInteger" } },
                    } },
            })
        end)

        it("as the last parameter of a synthesized record function (`new`)", function()
            -- Records desugar each field into a `new` record function; this
            -- confirms the synthesized function still parses through the same
            -- parameter machinery as user-written record functions.
            assert_program_ast([[
                record Point
                    x: integer
                    y: integer
                end
            ]], {
                { _tag = "Ast.TopLevelRecord", name = "Point" },
                { _tag = "Ast.TopLevelStatic", name = "new",
                    flexrettype = nil,
                    params = {
                        { _tag = "Ast.Decl", name = "x" },
                        { _tag = "Ast.Decl", name = "y" },
                    } },
            })
        end)

        it("as the last parameter of a lambda", function()
            assert_program_ast([[
                function f(): integer
                    local g = function(a, ...: integer) return a end
                    return 1
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    block = { stats = {
                        { _tag = "Ast.StatDecl",
                            exps = {
                                { _tag = "Ast.ExpFunction",
                                    params = {
                                        { _tag = "Ast.Decl", name = "a" },
                                        { _tag = "Ast.Decl", name = nil,
                                          type = { _tag = "Ast.TypeInteger" } },
                                    } } } } } } },
            })
        end)

        it("rejects a vararg that is not the last function parameter", function()
            assert_program_syntax_error([[
                function foo(...: integer, a: integer): nil
                end
            ]], "RParPList")
        end)

        it("rejects a vararg that is not the last lambda parameter", function()
            assert_program_syntax_error([[
                function f(): nil
                    local g = function(...: integer, a) return a end
                end
            ]], "RParPList")
        end)

        it("rejects an untyped vararg parameter (top-level requires `: type`)", function()
            -- `...` with no `:` in a top-level function: the colon is mandatory.
            assert_program_syntax_error([[
                function foo(...): nil
                end
            ]], "VarargColon")
        end)

        it("rejects the OLD no-colon vararg form `...integer`", function()
            -- The pre-colon surface syntax `...integer` (no `:`) is now a syntax
            -- error: after `...` the grammar demands a `:`.
            assert_program_syntax_error([[
                function foo(...integer): nil
                end
            ]], "VarargColon")
        end)

        it("rejects the OLD no-colon vararg form in a lambda", function()
            -- A lambda's vararg colon is OPTIONAL, so `...integer` parses `...` as
            -- an untyped vararg and then the stray `integer` makes the param list
            -- fail to close: the no-colon form no longer reads `integer` as the
            -- element type.
            assert_program_syntax_error([[
                function f(): nil
                    local g = function(...integer) return 1 end
                end
            ]], "RParPList")
        end)

        it("accepts an UNTYPED vararg lambda parameter `function (a, ...)`", function()
            -- A lambda's `...` may omit the element type (inferred from context).
            -- The vararg Decl carries name == nil AND type == nil.
            assert_program_ast([[
                function f(): integer
                    local g = function(a, ...) return a end
                    return 1
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    block = { stats = {
                        { _tag = "Ast.StatDecl",
                            exps = {
                                { _tag = "Ast.ExpFunction",
                                    params = {
                                        { _tag = "Ast.Decl", name = "a",
                                          type = nil },
                                        { _tag = "Ast.Decl", name = nil,
                                          type = nil },
                                    } } } } } } },
            })
        end)

        it("accepts a SOLE untyped vararg lambda parameter `function (...)`", function()
            assert_program_ast([[
                function f(): integer
                    local g = function(...) return 1 end
                    return 1
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    block = { stats = {
                        { _tag = "Ast.StatDecl",
                            exps = {
                                { _tag = "Ast.ExpFunction",
                                    params = {
                                        { _tag = "Ast.Decl", name = nil,
                                          type = nil },
                                    } } } } } } },
            })
        end)

        -- Disambiguation: `function(...): T` is an UNTYPED vararg whose `)`
        -- precedes the return-type `:`, while `function(...: T)` is a TYPED
        -- vararg. Pin both parses.
        it("parses `function(...): integer` as untyped-vararg + integer return", function()
            assert_program_ast([[
                function f(): integer
                    local g = function(...): integer return 1 end
                    return 1
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    block = { stats = {
                        { _tag = "Ast.StatDecl",
                            exps = {
                                { _tag = "Ast.ExpFunction",
                                    params = {
                                        { _tag = "Ast.Decl", name = nil,
                                          type = nil },
                                    },
                                    rettypes = { { _tag = "Ast.TypeInteger" } },
                                } } } } } },
            })
        end)

        it("parses `function(...: integer)` as a typed vararg", function()
            assert_program_ast([[
                function f(): integer
                    local g = function(...: integer) return 1 end
                    return 1
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    block = { stats = {
                        { _tag = "Ast.StatDecl",
                            exps = {
                                { _tag = "Ast.ExpFunction",
                                    params = {
                                        { _tag = "Ast.Decl", name = nil,
                                          type = { _tag = "Ast.TypeInteger" } },
                                    } } } } } } },
            })
        end)

        it("rejects an untyped vararg in a function-type annotation", function()
            -- A function-TYPE annotation still requires `...: type` (no inference).
            assert_program_syntax_error([[
                function f(g: function(...): integer): nil
                end
            ]], "VarargColon")
        end)

        -- Function-type vararg elements can be bare or explicitly grouped.
        it("parses a bare function-type vararg element `...: () -> integer`", function()
            assert_program_ast([[
                function foo(...: function (): (integer)): nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    name = "foo",
                    params = {
                        { _tag = "Ast.Decl", name = nil,
                          type = { _tag = "Ast.TypeFunction",
                                   argtypes = {},
                                   rettypes = { { _tag = "Ast.TypeInteger" } } } },
                    } },
            })
        end)

        it("parses a parenthesized function-type vararg element", function()
            assert_program_ast([[
                function foo(...: function (): (integer)): nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc", name = "foo",
                    params = { { _tag = "Ast.Decl", name = nil,
                        type = { _tag = "Ast.TypeFunction",
                            argtypes = {},
                            rettypes = { { _tag = "Ast.TypeInteger" } },
                            varargtype = nil, flexrettype = nil } } } },
            })
        end)
    end)

    describe("can parse variadic function-type annotations", function()
        it("with a fixed prefix and a vararg element type", function()
            assert_type_ast("function (integer, ...: string): (integer)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeInteger" } },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeString" } })
        end)

        it("with a sole vararg element type", function()
            assert_type_ast("function (...: integer): (integer)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeInteger" } })
        end)

        it("a non-variadic function type carries varargtype = nil", function()
            assert_type_ast("function (integer, string): (integer)",
                { _tag = "Ast.TypeFunction",
                    argtypes = {
                        { _tag = "Ast.TypeInteger" },
                        { _tag = "Ast.TypeString" },
                    },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = nil,
                    flexrettype = nil })
        end)
    end)

    describe("can parse flexible returns", function()
        it("as the sole return of a module function", function()
            assert_program_ast([[
                function names(): (...: string)
                end
            ]], {
                { _tag = "Ast.TopLevelFunc", name = "names",
                    rettypes = {},
                    flexrettype = { _tag = "Ast.TypeString" } },
            })
        end)

        it("after a fixed return of a record function and method", function()
            assert_program_ast([[
                function Box.make(): (boolean, ...: integer)
                end
                function Box:items(): (string, ...: value)
                end
            ]], {
                { _tag = "Ast.TopLevelStatic", class = "Box", name = "make",
                    rettypes = { { _tag = "Ast.TypeBoolean" } },
                    flexrettype = { _tag = "Ast.TypeInteger" } },
                { _tag = "Ast.TopLevelMethod", class = "Box", name = "items",
                    rettypes = { { _tag = "Ast.TypeString" } },
                    flexrettype = { _tag = "Ast.TypeValue" } },
            })
        end)

        it("on an anonymous function", function()
            assert_program_ast([[
                function outer(): nil
                    local f = function(): (boolean, ...: integer)
                        return true
                    end
                    return nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc", block = { stats = {
                    { _tag = "Ast.StatDecl", exps = {
                        { _tag = "Ast.ExpFunction",
                            rettypes = { { _tag = "Ast.TypeBoolean" } },
                            flexrettype = { _tag = "Ast.TypeInteger" } },
                    } },
                } } },
            })
        end)

        it("on function types, including simultaneous input and output tails", function()
            assert_type_ast(
                "function (integer, ...: string): (boolean, ...: value)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeString" },
                    rettypes = { { _tag = "Ast.TypeBoolean" } },
                    flexrettype = { _tag = "Ast.TypeValue" } })
            assert_type_ast("function (): (...: integer)",
                { _tag = "Ast.TypeFunction", argtypes = {}, rettypes = {},
                    varargtype = nil,
                    flexrettype = { _tag = "Ast.TypeInteger" } })
            assert_type_ast("function (): (...: function (): (integer))",
                { _tag = "Ast.TypeFunction", rettypes = {},
                    flexrettype = { _tag = "Ast.TypeFunction",
                        argtypes = {},
                        rettypes = { { _tag = "Ast.TypeInteger" } },
                        flexrettype = nil } })
        end)

        it("keeps an explicit fixed-empty lambda distinct from no annotation", function()
            assert_program_ast([[
                function outer(): nil
                    local inferred = function() end
                    local empty = function(): () end
                    return nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc", block = { stats = {
                    { _tag = "Ast.StatDecl", exps = {
                        { _tag = "Ast.ExpFunction", rettypes = nil,
                            flexrettype = nil },
                    } },
                    { _tag = "Ast.StatDecl", exps = {
                        { _tag = "Ast.ExpFunction", rettypes = {},
                            flexrettype = nil },
                    } },
                } } },
            })
        end)

        it("rejects a tail before a fixed return or a second tail", function()
            assert_program_syntax_error([[
                function bad(): (...: integer, string)
                end
            ]], "FlexRetLast")
            assert_program_syntax_error([[
                function bad(): (integer, ...: string, ...: value)
                end
            ]], "FlexRetLast")
        end)

        it("requires a comma between a fixed prefix and the flexible tail", function()
            assert_program_syntax_error([[
                function bad(): (integer ...: string)
                end
            ]], "RParenTypelist")
        end)

        it("uses return-specific errors for a missing colon or type", function()
            assert_program_syntax_error([[
                function bad(): (... integer)
                end
            ]], "FlexRetColon")
            assert_program_syntax_error([[
                function bad(): (...:)
                end
            ]], "FlexRetType")
        end)

        it("requires the tail to be inside a parenthesized return list", function()
            assert_program_syntax_error([[
                function bad(): ...: integer
                end
            ]], "FlexRetParens")
            assert_type_syntax_error("function(): ...: integer", "FlexRetParens")
        end)
    end)

    describe("can parse the `...` spread expression", function()
        local function vararg_program(body)
            return util.render([[
                function foo(...: integer): nil
                    $BODY
                end
            ]], { BODY = body })
        end

        local function vararg_stats(body)
            local ast = assert_parses_successfuly(vararg_program(body))
            return ast[1].block.stats
        end

        it("parses a subset suffix with an omitted first bound", function()
            assert_expression_ast("items[, last]", {
                _tag = "Ast.ExpSubset",
                exp = { _tag = "Ast.ExpVar" },
                first = nil,
                last = { _tag = "Ast.ExpVar" },
            })
        end)

        it("parses a subset suffix with an omitted last bound", function()
            assert_expression_ast("items[first,]", {
                _tag = "Ast.ExpSubset",
                exp = { _tag = "Ast.ExpVar" },
                first = { _tag = "Ast.ExpVar" },
                last = nil,
            })
        end)

        it("parses a subset suffix with both bounds", function()
            assert_expression_ast("items[first, last]", {
                _tag = "Ast.ExpSubset",
                exp = { _tag = "Ast.ExpVar" },
                first = { _tag = "Ast.ExpVar" },
                last = { _tag = "Ast.ExpVar" },
            })
        end)

        it("chains ordinary index and subset suffixes distinctly", function()
            assert_expression_ast("items[index][first, last]", {
                _tag = "Ast.ExpSubset",
                exp = {
                    _tag = "Ast.ExpVar",
                    var = { _tag = "Ast.VarBracket" },
                },
                first = { _tag = "Ast.ExpVar" },
                last = { _tag = "Ast.ExpVar" },
            })

            assert_expression_ast("items[first, last][index]", {
                _tag = "Ast.ExpVar",
                var = {
                    _tag = "Ast.VarBracket",
                    exp1 = { _tag = "Ast.ExpSubset" },
                    exp2 = { _tag = "Ast.ExpVar" },
                },
            })
        end)

        it("spreads a collection as a sole call argument", function()
            local stats = vararg_stats("f(...items)")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                    callexp = { args = { args = {
                        { _tag = "Ast.ExpSpread",
                          exp = { _tag = "Ast.ExpVar" },
                          first = nil,
                          last = nil },
                    } } } },
            }, stats)
        end)

        it('defers non-tail bare vararg rejection to the checker', function()

        local stats=vararg_stats("return 1 + ..., ..., 1")
        assert.equal("Ast.ExpBinop",stats[1].exps[1]._tag)
        assert.equal("Ast.ExpDots",stats[1].exps[2]._tag)
        assert.equal("Ast.ExpInteger",stats[1].exps[3]._tag)
    end)

        it("parses unary-leading collection subjects in explists", function()
            local stats = vararg_stats([[
                return ... - 1
            ]])
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                  exps = {
                      { _tag = "Ast.ExpSpread",
                        exp = { _tag = "Ast.ExpUnop", op = "-" } },
                  } },
            }, stats)

            stats = vararg_stats("return ... ~1")
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                  exps = {
                      { _tag = "Ast.ExpSpread",
                        exp = { _tag = "Ast.ExpUnop", op = "~" } },
                  } },
            }, stats)
        end)

        it("parses `(...)` as an explicit one-value adjustment", function()
            local stats = vararg_stats("return (...) - 1")
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                  exps = {
                      { _tag = "Ast.ExpBinop", op = "-",
                        lhs = { _tag = "Ast.ExpAdjust",
                            exp = { _tag = "Ast.ExpDots" } },
                        rhs = { _tag = "Ast.ExpInteger", value = 1 } },
                  } },
            }, stats)
        end)

        it("keeps the exact parenthesized-dots branch suffix-safe", function()
            local stats = vararg_stats([[
                x = (...[1])
                y = (...)[1]
                z = ((...));
                (...)()
            ]])
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                  exps = { { _tag = "Ast.ExpDotsIndex" } } },
                { _tag = "Ast.StatAssign",
                  exps = { { _tag = "Ast.ExpVar", var = {
                      _tag = "Ast.VarBracket",
                      exp1 = { _tag = "Ast.ExpAdjust" },
                  } } } },
                { _tag = "Ast.StatAssign",
                  exps = { { _tag = "Ast.ExpAdjust" } } },
                { _tag = "Ast.StatCall", callexp = {
                    exp = { _tag = "Ast.ExpAdjust" },
                } },
            }, stats)
        end)

        it('adjusts parenthesized spreads and varargs to one value', function()

        local stats=vararg_stats("x=(...items) y=(...) z=(... - 1)")
        assert.equal("Ast.ExpAdjust",stats[1].exps[1]._tag)
        assert.equal("Ast.ExpSpread",stats[1].exps[1].exp._tag)
        assert.equal("Ast.ExpAdjust",stats[2].exps[1]._tag)
        assert.equal("Ast.ExpDots",stats[2].exps[1].exp._tag)
        assert.equal("Ast.ExpSpread",stats[3].exps[1].exp._tag)
    end)

        it("allows a parenthesized unary-leading spread subject", function()
            local stats = vararg_stats("f(...(-items))")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                  callexp = { args = { args = {
                      { _tag = "Ast.ExpSpread",
                        exp = { _tag = "Ast.ExpUnop", op = "-" } },
                  } } } },
            }, stats)
        end)

        it("spreads a collection subset as a trailing return value", function()
            local stats = vararg_stats(
                "return prefix, ...items[first, last]")
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                    exps = {
                        { _tag = "Ast.ExpVar" },
                        { _tag = "Ast.ExpSpread",
                          exp = {
                              _tag = "Ast.ExpSubset",
                              exp = { _tag = "Ast.ExpVar" },
                              first = { _tag = "Ast.ExpVar" },
                              last = { _tag = "Ast.ExpVar" },
                          } },
                    } },
            }, stats)
        end)

        it("spreads a collection subset as the final constructor field", function()
            local stats = vararg_stats("x = {prefix, ...items[, last]}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpInitList",
                        fields = {
                            { _tag = "Ast.Field",
                              exp = { _tag = "Ast.ExpVar" } },
                            { _tag = "Ast.Field", name = nil,
                              exp = { _tag = "Ast.ExpSpread",
                                  exp = {
                                      _tag = "Ast.ExpSubset",
                                      first = nil,
                                      last = { _tag = "Ast.ExpVar" },
                                  } } },
                        } } } },
            }, stats)
        end)

        it("keeps an ordinary index inside a spread subject", function()
            local stats = vararg_stats("f(...items[index])")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                    callexp = { args = { args = {
                        { _tag = "Ast.ExpSpread",
                          exp = {
                              _tag = "Ast.ExpVar",
                              var = { _tag = "Ast.VarBracket" },
                          } },
                    } } } },
            }, stats)
        end)

        it("allows an indexed vararg value as a spread subject", function()
            local stats = vararg_stats("f(... ...[1])")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                    callexp = { args = { args = {
                        { _tag = "Ast.ExpSpread",
                          exp = { _tag = "Ast.ExpDotsIndex" },
                        },
                    } } } },
            }, stats)
        end)

        it('retains all vararg ranges for checker-owned tail elaboration', function()

        local stats=vararg_stats("f(...[1,2], ...[,2], ...[1,])")
        local args=stats[1].callexp.args.args
        for _,exp in ipairs(args) do
            assert.equal("Ast.ExpSubset",exp._tag)
            assert.equal("Ast.ExpDots",exp.exp._tag)
        end
        assert.is_nil(args[2].first)
        assert.is_nil(args[3].last)
    end)

        it("parses a bracketed vararg slice explicitly in scalar grammar",
        function()
            local stats = vararg_stats("x = (...[first, last])")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                  exps = {
                      { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpSubset",
                        exp = { _tag = "Ast.ExpDots" },
                        first = { _tag = "Ast.ExpVar" },
                        last = { _tag = "Ast.ExpVar" } } },
                  } },
            }, stats)

            stats = vararg_stats("x = {(...[first, last]), 3}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                  exps = { { _tag = "Ast.ExpInitList", fields = {
                      { exp = { _tag = "Ast.ExpAdjust", exp = { _tag = "Ast.ExpSubset" } } },
                      { exp = { _tag = "Ast.ExpInteger", value = 3 } },
                  } } } },
            }, stats)
        end)

        it('keeps bare input varargs distinct from collection spreads', function()

        local stats=vararg_stats("f(..., ...items, ...[1], ...[1,2])")
        local args=stats[1].callexp.args.args
        assert.equal("Ast.ExpDots",args[1]._tag)
        assert.equal("Ast.ExpSpread",args[2]._tag)
        assert.equal("Ast.ExpDotsIndex",args[3]._tag)
        assert.equal("Ast.ExpSubset",args[4]._tag)
        assert.equal("Ast.ExpDots",args[4].exp._tag)
    end)

        it("leaves non-tail explicit spreads for checker diagnostics",
        function()
            local stats = vararg_stats([[
                f(prefix, ...items, suffix)
                x = {prefix, ...items, suffix}
                f(...[1, 2], suffix)
                x = {...[1, 2], suffix}
            ]])
            assert_is_subset({
                { _tag = "Ast.StatCall", callexp = { args = { args = {
                    { _tag = "Ast.ExpVar" },
                    { _tag = "Ast.ExpSpread" },
                    { _tag = "Ast.ExpVar" },
                } } } },
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpInitList", fields = {
                        { exp = { _tag = "Ast.ExpVar" } },
                        { exp = { _tag = "Ast.ExpSpread" } },
                        { exp = { _tag = "Ast.ExpVar" } },
                    } },
                } },
                { _tag = "Ast.StatCall", callexp = { args = { args = {
                    { _tag = "Ast.ExpSubset",
                      exp = { _tag = "Ast.ExpDots" } },
                    { _tag = "Ast.ExpVar" },
                } } } },
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpInitList", fields = {
                        { exp = { _tag = "Ast.ExpSubset",
                          exp = { _tag = "Ast.ExpDots" } },
                        },
                        { exp = { _tag = "Ast.ExpVar" } },
                    } },
                } },
            }, stats)
        end)

        it("as a sole call argument: f(...)", function()
            local stats = vararg_stats("f(...)")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                    callexp = { args = { args = {
                        { _tag = "Ast.ExpDots" },
                    } } } },
            }, stats)
        end)

        it("as a trailing call argument: f(a, ...)", function()
            local stats = vararg_stats("f(a, ...)")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                    callexp = { args = { args = {
                        { _tag = "Ast.ExpVar" },
                        { _tag = "Ast.ExpDots" },
                    } } } },
            }, stats)
        end)

        it("as a sole return value: return ...", function()
            local stats = vararg_stats("return ...")
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                    exps = { { _tag = "Ast.ExpDots" } } },
            }, stats)
        end)

        it("as a trailing return value: return a, ...", function()
            local stats = vararg_stats("return a, ...")
            assert_is_subset({
                { _tag = "Ast.StatReturn",
                    exps = {
                        { _tag = "Ast.ExpVar" },
                        { _tag = "Ast.ExpDots" },
                    } },
            }, stats)
        end)

        it("as a sole array-constructor field: {...}", function()
            local stats = vararg_stats("x = {...}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpInitList",
                        fields = {
                            { _tag = "Ast.Field", name = nil,
                              exp = { _tag = "Ast.ExpDots" } },
                        } } } },
            }, stats)
        end)

        it("as a trailing array-constructor field: {a, ...}", function()
            local stats = vararg_stats("x = {a, ...}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpInitList",
                        fields = {
                            { _tag = "Ast.Field",
                              exp = { _tag = "Ast.ExpVar" } },
                            { _tag = "Ast.Field", name = nil,
                              exp = { _tag = "Ast.ExpDots" } },
                        } } } },
            }, stats)
        end)

        it("indexes `...[e]` as a sole array-constructor field: {...[1]}", function()
            local stats = vararg_stats("x = {...[1]}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpInitList",
                        fields = {
                            { _tag = "Ast.Field", name = nil,
                              exp = { _tag = "Ast.ExpDotsIndex",
                                  exp = { _tag = "Ast.ExpInteger", value = 1 } } },
                        } } } },
            }, stats)
        end)

        it("indexes `...[e]` as a trailing array-constructor field: {a, ...[i]}", function()
            local stats = vararg_stats("x = {a, ...[i]}")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpInitList",
                        fields = {
                            { _tag = "Ast.Field",
                              exp = { _tag = "Ast.ExpVar" } },
                            { _tag = "Ast.Field", name = nil,
                              exp = { _tag = "Ast.ExpDotsIndex",
                                  exp = { _tag = "Ast.ExpVar" } } },
                        } } } },
            }, stats)
        end)

        it("indexes `...[e]` as an ExpDotsIndex", function()
            local stats = vararg_stats("x = ...[1]")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpDotsIndex",
                        exp = { _tag = "Ast.ExpInteger", value = 1 } } } },
            }, stats)
        end)

        it("indexes `...[e]` with a compound index expression", function()
            local stats = vararg_stats("x = ...[i + 1]")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpDotsIndex",
                        exp = { _tag = "Ast.ExpBinop", op = "+" } } } },
            }, stats)
        end)

        it("keeps `...[e]` scalar before another list item", function()
            local stats = vararg_stats("f(...[1], 2)")
            assert_is_subset({
                { _tag = "Ast.StatCall",
                  callexp = { args = { args = {
                      { _tag = "Ast.ExpDotsIndex" },
                      { _tag = "Ast.ExpInteger", value = 2 },
                  } } } },
            }, stats)
        end)

        it("parses `#...` through its explicit variadic expression", function()
            local stats = vararg_stats("x = #...")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpDotsLen" } } },
            }, stats)
        end)

        it("keeps unary `#` on an explicit `...[e]` value", function()
            local stats = vararg_stats("x = #...[1]")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpUnop", op = "#",
                        exp = { _tag = "Ast.ExpDotsIndex" } } } },
            }, stats)
        end)

        it("parses complete continuations after DOTS bracket expressions",
        function()
            local stats = vararg_stats([[
                a = ...[1] + 2
                b = ...[1] as integer
                c = ...[1] ^ 2
                d = ...[1, 2] + 3
            ]])
            assert_is_subset({
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpBinop", op = "+",
                      lhs = { _tag = "Ast.ExpDotsIndex" } },
                } },
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpCast",
                      exp = { _tag = "Ast.ExpDotsIndex" } },
                } },
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpBinop", op = "^",
                      lhs = { _tag = "Ast.ExpDotsIndex" } },
                } },
                { _tag = "Ast.StatAssign", exps = {
                    { _tag = "Ast.ExpBinop", op = "+",
                      lhs = { _tag = "Ast.ExpSubset" } },
                } },
            }, stats)
        end)
    end)

    describe("enforces the parser list length limit", function()
        local function repeated(template, n, sep)
            local parts = {}
            for i = 1, n do parts[i] = string.format(template, i) end
            return table.concat(parts, sep)
        end

        it("accepts a 100-element parameter list", function()
            local src = "function foo(" ..
                repeated("p%d: integer", 100, ", ") .. "): nil\nend"
            assert_parses_successfuly(src)
        end)

        it("rejects a 101-element parameter list with ListTooLong", function()
            local src = "function foo(" ..
                repeated("p%d: integer", 101, ", ") .. "): nil\nend"
            assert_program_syntax_error(src, "ListTooLong")
        end)

        it("accepts a 100-element expression list", function()
            local src = "function foo(): nil\n  return " ..
                repeated("%d", 100, ", ") .. "\nend"
            assert_parses_successfuly(src)
        end)

        it("rejects a 101-element expression list with ListTooLong", function()
            local src = "function foo(): nil\n  return " ..
                repeated("%d", 101, ", ") .. "\nend"
            assert_program_syntax_error(src, "ListTooLong")
        end)

        it("counts explicit scalars but not an open tail marker", function()
            local fixed = repeated("%d", 100, ", ")
            assert_parses_successfuly(
                "function foo(items: {integer}, ...: integer): nil\n" ..
                "  return " .. fixed .. ", ...\nend")
            assert_parses_successfuly(
                "function foo(items: {integer}, ...: integer): nil\n" ..
                "  return " .. fixed .. ", ...items\nend")

            assert_program_syntax_error(
                "function foo(...: integer): nil\n  return " ..
                fixed .. ", ...[1]\nend", "ListTooLong")
            assert_program_syntax_error(
                "function foo(...: integer): nil\n  return " ..
                fixed .. ", (...)\nend", "ListTooLong")
        end)

        it("does not exempt a non-tail spread from the list cap", function()
            local fixed = repeated("%d", 100, ", ")
            assert_program_syntax_error(
                "function foo(items: {integer}): nil\n  return " ..
                fixed .. ", ...items, 0\nend", "ListTooLong")
        end)

        it("rejects a 101-element lambda parameter list with ListTooLong", function()
            local src = "function f(): nil\n  local g = function(" ..
                repeated("p%d", 101, ", ") .. ") return 1 end\nend"
            assert_program_syntax_error(src, "ListTooLong")
        end)

        it("applies the limit to type parameter lists", function()
            local accepted = "record Many<|" ..
                repeated("T%d", 100, ", ") .. "|> end"
            assert_parses_successfuly(accepted)

            local rejected = "record TooMany<|" ..
                repeated("T%d", 101, ", ") .. "|> end"
            assert_program_syntax_error(rejected, "ListTooLong")
        end)

        it("applies the limit to type argument lists", function()
            local accepted_args = repeated("T%d", 100, ", ")
            local accepted = "Holder<|" .. accepted_args .. "|>"
            assert_type_ast(accepted, { _tag = "Ast.TypeName" })
            assert_expression_ast("make<|" .. accepted_args .. "|>()", {
                _tag = "Ast.ExpCall",
            })

            local rejected_args = repeated("T%d", 101, ", ")
            local rejected = "Holder<|" .. rejected_args .. "|>"
            assert_type_syntax_error(rejected, "ListTooLong")
            assert_expression_syntax_error(
                "make<|" .. rejected_args .. "|>()", "ListTooLong")
        end)
    end)

    describe("preserves factored grammar ASTs and diagnostics", function()
        it('keeps the specified non-associative cast and type-test precedence', function()

        assert_expression_ast("a + b as T",{op="+",rhs={_tag="Ast.ExpCast"}})
        assert_expression_ast("a * b is T",{op="*",rhs={_tag="Ast.ExpIs"}})
        assert_expression_ast("a ^ b as T",{_tag="Ast.ExpCast",exp={op="^"}})
        assert_expression_ast("not a is T",{_tag="Ast.ExpIs",exp={op="not"}})
        assert_expression_ast("(a as T) as U",{_tag="Ast.ExpCast",
            exp={_tag="Ast.ExpCast"}})
        assert_expression_syntax_error("a as T as U","EndFunc")
    end)

        it("keeps parenthesized call adjustment and suffix ASTs", function()
            local adjusted = assert_expression_ast("(((f())))", {
                _tag = "Ast.ExpAdjust",
                exp = { _tag = "Ast.ExpCall" },
            })
            -- The historical grammar collapses these redundant parentheses
            -- to one adjustment around the call.
            assert.are.equal("Ast.ExpCall", adjusted.exp._tag)

            assert_expression_ast("(object).field", {
                _tag = "Ast.ExpVar",
                var = {
                    _tag = "Ast.VarDot",
                    name = "field",
                    exp = {
                        _tag = "Ast.ExpVar",
                        var = { _tag = "Ast.VarName", name = "object" },
                    },
                },
            })
        end)

        it('right-folds power with right-hand prefixes and suffixes', function()

        assert_expression_ast("a ^ -b ^ ~c",{op="^",rhs={op="-",exp={
            op="^",rhs={op="~"}}}})
        assert_expression_ast("a ^ -b() ^ c[1]",{op="^",rhs={op="-",exp={
            op="^",lhs={_tag="Ast.ExpCall"},rhs={_tag="Ast.ExpVar"}}}})
        assert_expression_ast("a ^ b as T",{_tag="Ast.ExpCast",exp={op="^"}})
    end)

        it("right-folds and flattens parenthesized concatenation", function()
            local concat = assert_expression_ast("a .. (b .. c)", {
                _tag = "Ast.ExpConcat",
                exps = {
                    { var = { name = "a" } },
                    { var = { name = "b" } },
                    { var = { name = "c" } },
                },
            })
            -- The historical right fold retains the location of the first
            -- concat node constructed in the right-hand suffix.
            assert.is_true(rawequal(concat.loc, concat.exps[2].loc))
        end)

        it('keeps nested nominal applications and function results', function()

        assert_type_ast("Box<|function(T): Box<|U|>|>",{_tag="Ast.TypeName",name="Box",
            typeargs={{_tag="Ast.TypeFunction",rettypes={{name="Box"}}}}})
        assert_type_ast("function(T): function(U): V",{_tag="Ast.TypeFunction",
            rettypes={{_tag="Ast.TypeFunction",rettypes={{name="V"}}}}})
    end)

        it("distinguishes nested Array and Map tails after one key type", function()
            assert_type_ast("{{T}: {U: {V}}}", {
                _tag = "Ast.TypeMap",
                keystype = {
                    _tag = "Ast.TypeArray",
                    subtype = { _tag = "Ast.TypeName", name = "T" },
                },
                valuestype = {
                    _tag = "Ast.TypeMap",
                    keystype = { _tag = "Ast.TypeName", name = "U" },
                    valuestype = {
                        _tag = "Ast.TypeArray",
                        subtype = { _tag = "Ast.TypeName", name = "V" },
                    },
                },
            })
        end)

        it('retains grouped owned-array pointer source locations', function()

        local source="local x: owned (*Item)[] = nil"
        local p=assert(parser.parse("owned-loc.titan",source))
        local owner=p[1].decl.type
        assert.equal("Ast.TypeOwned",owner._tag)
        assert.equal("Ast.TypeCArray",owner.subtype._tag)
        assert.equal("Ast.TypeCPointer",owner.subtype.base._tag)
        assert.equal(source:find("*",1,true),owner.subtype.base.loc.col)
        assert.equal("Item",owner.subtype.base.subtype.name)
    end)

        it('parses owned alias operands and diagnoses malformed raw syntax', function()

        assert_type_syntax_error("owned *(*", "TypeDecl")
        assert_type_syntax_error("owned (int[4])", "RBracketCArray")
        assert_type_ast("owned Handle",{_tag="Ast.TypeOwned",
            subtype={_tag="Ast.TypeForeignName",name="Handle"}})
    end)

        it("classifies assignment and call statements from one prefix", function()
            assert_statements_ast([[
                target.items[index], other = make(), rhs
                target:run(callback(arg))
            ]], {
                {
                    _tag = "Ast.StatAssign",
                    vars = {
                        { _tag = "Ast.VarBracket" },
                        { _tag = "Ast.VarName", name = "other" },
                    },
                    exps = {
                        { _tag = "Ast.ExpCall" },
                        { _tag = "Ast.ExpVar" },
                    },
                },
                {
                    _tag = "Ast.StatCall",
                    callexp = {
                        _tag = "Ast.ExpCall",
                        args = {
                            _tag = "Ast.ArgsMethod",
                            method = "run",
                            args = { { _tag = "Ast.ExpCall" } },
                        },
                    },
                },
            })
        end)

        it('retains labels at each factored decision point', function()

        assert_expression_syntax_error("a +", "OpExp")
        assert_expression_syntax_error("a. )", "NameDotExpSuf")
        assert_expression_syntax_error("a: )", "NameColonExpSuf")
        assert_expression_syntax_error("a[", "ExpExpSuf")
        assert_expression_syntax_error("a[1,", "RBracketExpSuf")
        assert_expression_syntax_error("a<|T,|>()", "TypeArgument")
        assert_type_syntax_error("Pair<|T", "RAngleTypeArgs")
        assert_type_syntax_error("{T:}", "TypeType")
        assert_type_syntax_error("{T", "RCurlyType")
    end)

        it("keeps the malformed call-tail statement boundary", function()
            local program, err = parser.parse(
                "call-tail-error.titan", "function p() f() + y end")
            assert.falsy(program)
            assert.are.equal("EndFunc", err.label)
            assert.are.same({
                filename = "call-tail-error.titan",
                line = 1,
                col = 18,
            }, err.loc)
        end)

        it("keeps the malformed non-call suffix failure position", function()
            local program, err = parser.parse(
                "suffix-tail-error.titan", "function p() 1 .. y . ^ end")
            assert.falsy(program)
            -- The factored simple-expression path does not retry the parsed
            -- prefix solely to relabel this malformed statement as ExpStat.
            assert.are.equal("EndFunc", err.label)
            assert.are.same({
                filename = "suffix-tail-error.titan",
                line = 1,
                col = 16,
            }, err.loc)
        end)
    end)

    describe("keeps recursive grammar traversal within a linear budget", function()
        local budget = 100000

        it("parses nested ordinary calls without tripling each operand", function()
            local expression = "x"
            for _ = 1, 5 do
                expression = "f(" .. expression .. ")"
            end
            parse_under_instruction_budget(
                expression_test_program(expression), budget)
        end)

        it("parses nested indexes without retrying them as subsets", function()
            local expression = "x"
            for _ = 1, 17 do
                expression = "x[" .. expression .. "]"
            end
            parse_under_instruction_budget(
                expression_test_program(expression), budget)
        end)

        it("classifies nested vararg indexes once per explist item", function()
            local expression = "1"
            for _ = 1, 7 do
                expression = "f(0, ...[" .. expression .. "], 1)"
            end
            parse_under_instruction_budget(
                "function f(...: integer): nil\n" ..
                "    x = " .. expression .. "\n" ..
                "end", 30000)
        end)

        it("parses nested parentheses without duplicating each prefix", function()
            local expression = "x"
            for _ = 1, 3 do
                expression = "(" .. expression .. ")"
            end
            parse_under_instruction_budget(
                expression_test_program(expression), budget)
        end)

        it("parses nested generic types without retrying each simple type",
        function()
            local type_string = "T"
            for _ = 1, 8 do
                type_string = "Node<|" .. type_string .. "|>"
            end
            parse_under_instruction_budget(
                type_test_program(type_string), budget)
        end)

        it("bounds failed generic-call probes with missing closes", function()
            local parts = { "f" }
            for _ = 1, 100 do
                parts[#parts + 1] = " < Box"
            end
            parse_under_instruction_budget(
                expression_test_program(table.concat(parts)), budget)
        end)

        it('disambiguates nested parenthesized return types once', function()

        local typ="integer"
        for _=1,24 do typ="function(integer): ("..typ..")" end
        parse_under_instruction_budget(type_test_program(typ),100000)
    end)

        it("bounds nested grouped optional types and their malformed counterparts", function()
            local typ = "T"
            for _ = 1, 16 do typ = "({(" .. typ .. ")})?" end
            parse_under_instruction_budget(type_test_program(typ), budget)
            parse_under_instruction_budget(
                "function f(): " .. typ .. " end", budget)
            parse_under_instruction_budget(
                type_test_program("(" .. typ), budget, "RParenTypelist")
            parse_under_instruction_budget(
                type_test_program("(" .. typ .. ", U)"), budget,
                "RParenTypelist")
        end)

        it('folds wide function-type lists without a capture-result explosion', function()

        local arguments={}
        for _=1,100 do arguments[#arguments+1]="((T))?" end
        local typ="function("..table.concat(arguments,",").."): ()"
        parse_under_instruction_budget(type_test_program(typ),200000)
        parse_under_instruction_budget(type_test_program(typ.."?"),200000,"OptionTypeList")
    end)

        it("parses nested Arrays without retrying them as Maps", function()
            local type_string = "T"
            for _ = 1, 4 do
                type_string = "{" .. type_string .. "}"
            end
            parse_under_instruction_budget(
                type_test_program(type_string), budget)
        end)

        it('parses nested grouped foreign pointers without lookahead reparsing', function()

        local typ="Item"
        for _=1,12 do typ="*("..typ..")" end
        parse_under_instruction_budget(type_test_program("owned "..typ),budget)
    end)

        it('parses long power chains without recursive stack growth', function()

        local function measure(count)
            local parts={"x"}
            for i=1,count do parts[#parts+1]=i%2==0 and " ^ -x" or " ^ x" end
            local _,instructions=parse_under_instruction_budget(
                expression_test_program(table.concat(parts)),400000)
            return instructions
        end
        local small=measure(100)
        local large=measure(200)
        assert.is_true(large < small * 2.5)
        assert.is_true(large > small)
    end)

        it("parses long concat chains without recursive stack growth", function()
            local parts = { "x" }
            for _ = 1, 200 do
                parts[#parts + 1] = " .. x"
            end
            parse_under_instruction_budget(
                expression_test_program(table.concat(parts)), budget)
        end)

        it("classifies nested callback call statements once", function()
            local lines = { "local function probe()" }
            local depth = 4
            for i = 1, depth do
                lines[#lines + 1] = string.rep("    ", i) ..
                    string.format("context:run(\"case%d\", function()", i)
            end
            lines[#lines + 1] = string.rep("    ", depth + 1) ..
                "sink(x)"
            for i = depth, 1, -1 do
                lines[#lines + 1] = string.rep("    ", i) .. "end)"
            end
            lines[#lines + 1] = "end"
            parse_under_instruction_budget(table.concat(lines, "\n"), budget)
        end)
    end)

    describe("interns source locations for one parse", function()
        local source = "function foo(): nil\n    x = y\nend"

        it("converts each byte position once and shares the location", function()
            local original_from_pos = location.from_pos
            local calls = {}
            location.from_pos = function(filename, input, pos)
                calls[pos] = (calls[pos] or 0) + 1
                return original_from_pos(filename, input, pos)
            end
            local ok, program, err = pcall(
                parser.parse, "interned-locations.titan", source)
            location.from_pos = original_from_pos

            assert.is_true(ok, tostring(program))
            assert.truthy(program, err and err.label or "parser returned no AST")
            assert.truthy(next(calls))
            for _, count in pairs(calls) do
                assert.are.equal(1, count)
            end

            local exp = program[1].block.stats[1].exps[1]
            assert.is_true(rawequal(exp.loc, exp.var.loc))
            assert.is_true(rawequal(exp.loc, exp.var._name_loc))
        end)

        it("starts with a fresh location table for every parse", function()
            local first = assert(parser.parse("first.titan", source))
            local second = assert(parser.parse("second.titan", source))
            local first_loc = first[1].block.stats[1].exps[1].loc
            local second_loc = second[1].block.stats[1].exps[1].loc

            assert.is_false(rawequal(first_loc, second_loc))
            assert.are.equal("first.titan", first_loc.filename)
            assert.are.equal("second.titan", second_loc.filename)
        end)

        it("clears parser state after an unexpected location error", function()
            local original_from_pos = location.from_pos
            location.from_pos = function()
                error("forced location conversion failure", 0)
            end
            local ok, err = pcall(parser.parse, "broken.titan", source)
            location.from_pos = original_from_pos

            assert.is_false(ok)
            assert.truthy(tostring(err):find(
                "forced location conversion failure", 1, true))

            local recovered = assert(parser.parse("recovered.titan", source))
            assert.are.equal("recovered.titan",
                recovered[1].block.stats[1].exps[1].loc.filename)
        end)

        it('parses comparisons without a generic candidate prescan', function()

        -- There is no source prescan or generic-call candidate table anymore.
        local grammar_source=assert(io.open("titan-compiler/parser.lua")):read("a")
        assert.is_nil(grammar_source:find("GENERIC_CALL_CANDIDATES",1,true))
        assert.is_nil(grammar_source:find("genericcalltypeargprobe",1,true))
        assert(parser.parse("comparisons.titan",expression_test_program("a < b < c")))
    end)

        it("keeps non-ASCII source columns byte based", function()
            local utf8_source =
                "function foo(): nil\n    x = \"é\" .. y\nend"
            local program = assert(parser.parse("utf8.titan", utf8_source))
            local concat = program[1].block.stats[1].exps[1]
            local y = concat.exps[2]

            assert.are.equal("Ast.ExpConcat", concat._tag)
            assert.are.same({
                filename = "utf8.titan",
                line = 2,
                col = 17,
            }, y.loc)
        end)
    end)

    describe("can parse error handling", function()
        it("parses `raise <exp>`", function()
            assert_statements_ast([[ raise "boom" ]], {
                { _tag = "Ast.StatRaise",
                  exp = { _tag = "Ast.ExpString", value = "boom" } }
            })
            assert_statements_ast([[ raise x + 1 ]], {
                { _tag = "Ast.StatRaise",
                  exp = { _tag = "Ast.ExpBinop", op = "+" } }
            })
        end)

        it("parses a bare `raise` (exp is nil)", function()
            assert_statements_ast([[ raise ]], {
                { _tag = "Ast.StatRaise", exp = nil }
            })
        end)

        it("parses a `do` block with only a catch", function()
            assert_statements_ast([[
                do
                    raise "x"
                catch
                    print(error)
                end
            ]], {
                { _tag = "Ast.StatTry",
                  block = { _tag = "Ast.StatBlock",
                            stats = { { _tag = "Ast.StatRaise" } } },
                  catchblock = { _tag = "Ast.StatBlock" },
                  finallyblock = nil }
            })
        end)

        it("attaches catch to a function body", function()
            assert_program_ast([[
                function f(): nil
                    print(1)
                catch
                    print(error)
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                  name = "f",
                  block = { _tag = "Ast.StatTry",
                            block = { _tag = "Ast.StatBlock" },
                            catchblock = { _tag = "Ast.StatBlock" },
                            finallyblock = nil } }
            })
        end)

        it("attaches catch to a loop body", function()
            assert_statements_ast([[
                while true do
                    raise "x"
                catch
                    break
                end
            ]], {
                { _tag = "Ast.StatWhile",
                  block = { _tag = "Ast.StatTry",
                            catchblock = { _tag = "Ast.StatBlock" },
                            finallyblock = nil } }
            })
        end)

        it("rejects `finally` as a block trailer", function()
            assert_statements_syntax_error([[
                do
                    print(1)
                finally
                    print(2)
                end
            ]], "EndBlock")
        end)

        it("lowers `defer <statement>` over the rest of its simpleblock", function()
            assert_statements_ast([[
                local x = 1
                defer cleanup()
                x = 2
                return
            ]], {
                { _tag = "Ast.StatDecl" },
                { _tag = "Ast.StatTry",
                  block = {
                      _tag = "Ast.StatBlock",
                      stats = {
                          { _tag = "Ast.StatAssign" },
                          { _tag = "Ast.StatReturn" }
                      }
                  },
                  catchblock = nil,
                  finallyblock = {
                      _tag = "Ast.StatBlock",
                      stats = {
                          { _tag = "Ast.StatCall",
                            callexp = {
                                _tag = "Ast.ExpCall",
                                exp = {
                                    _tag = "Ast.ExpVar",
                                    var = { _tag = "Ast.VarName", name = "cleanup" }
                                }
                            } }
                      }
                  } }
            })
        end)

        it("lowers multiple defers into nested finally blocks", function()
            assert_statements_ast([[
                defer first()
                defer second()
                work()
            ]], {
                { _tag = "Ast.StatTry",
                  block = {
                      _tag = "Ast.StatBlock",
                      stats = {
                          { _tag = "Ast.StatTry",
                            block = {
                                _tag = "Ast.StatBlock",
                                stats = {
                                    { _tag = "Ast.StatCall",
                                      callexp = {
                                          _tag = "Ast.ExpCall",
                                          exp = {
                                              _tag = "Ast.ExpVar",
                                              var = { _tag = "Ast.VarName", name = "work" }
                                          }
                                      } }
                                }
                            },
                            finallyblock = {
                                _tag = "Ast.StatBlock",
                                stats = {
                                    { _tag = "Ast.StatCall",
                                      callexp = {
                                          _tag = "Ast.ExpCall",
                                          exp = {
                                              _tag = "Ast.ExpVar",
                                              var = { _tag = "Ast.VarName", name = "second" }
                                          }
                                      } }
                                }
                            } }
                      }
                  },
                  finallyblock = {
                      _tag = "Ast.StatBlock",
                      stats = {
                          { _tag = "Ast.StatCall",
                            callexp = {
                                _tag = "Ast.ExpCall",
                                exp = {
                                    _tag = "Ast.ExpVar",
                                    var = { _tag = "Ast.VarName", name = "first" }
                                }
                            } }
                      }
                  } }
            })
        end)

        it("allows `defer do ... end` as a multi-statement cleanup", function()
            assert_statements_ast([[
                defer do
                    first()
                    second()
                end
                work()
            ]], {
                { _tag = "Ast.StatTry",
                  finallyblock = {
                      _tag = "Ast.StatBlock",
                      stats = {
                          { _tag = "Ast.StatBlock",
                            stats = {
                                { _tag = "Ast.StatCall" },
                                { _tag = "Ast.StatCall" }
                            } }
                      }
                  } }
            })
        end)

        it("rejects directly deferring another defer statement", function()
            assert_program_syntax_error([[
                function f(): nil
                    defer defer cleanup()
                end
            ]], "DeferDefer")
        end)

        it("rejects deferring an empty semicolon statement", function()
            assert_program_syntax_error([[
                function f(): nil
                    defer ;
                end
            ]], "DeferStatement")
        end)
    end)
end)


describe("unbound foreign imports", function()
    it("retains directive ordering and exact quoted-header locations", function()
        local tree = assert(parser.parse("ffi.titan", [[foreign import "one.h"
foreign import("two.h")
local function answer(): integer return ffi.VALUE end]]))
        assert.are.equal("Ast.TopLevelForeignImport", tree[1]._tag)
        assert.are.equal("one.h", tree[1].headername)
        assert.is_nil(tree[1].localname)
        assert.are.equal(1, tree[1]._header_loc.line)
        assert.are.equal(16, tree[1]._header_loc.col)
        assert.are.equal("two.h", tree[2].headername)
        assert.are.equal(2, tree[2]._header_loc.line)
        assert.are.equal(16, tree[2]._header_loc.col)
    end)

    it("rejects the retired bound import syntax", function()
        local tree, err = parser.parse("ffi.titan", 'local c = foreign import "one.h"')
        assert.falsy(tree)
        assert.are.equal("BoundForeignImport", err.label)
    end)

    it('allows ffi to be shadowed in ordinary binding namespaces', function()

        for _,source in ipairs({
            "local ffi = 1", 'local ffi = import "math"',
            "function ffi() end", "type ffi = integer",
            "record ffi n: integer end", "union ffi A() end",
            "interface ffi n: integer end", "function f(ffi: integer) end",
            "function f<|ffi|>() end", "function f() local ffi = 1 end",
        }) do assert_parses_successfuly(source) end
    end)

    it("keeps ffi valid as a member spelling and namespace use", function()
        assert(parser.parse("ffi.titan", [[record R ffi: integer end
function R.ffi(): integer return ffi.VALUE end
local function use(obj: R): integer return obj.ffi end]]))
    end)
end)

describe("simplified grammar boundaries", function()
    it("greedily associates function return colons before map separators", function()
        assert_type_ast("{function(): T}", {
            _tag = "Ast.TypeArray", subtype = {
                _tag = "Ast.TypeFunction", rettypes = {{name = "T"}},
            },
        })
        assert_type_ast("{(function()): T}", {
            _tag = "Ast.TypeMap", keystype = {
                _tag = "Ast.TypeFunction", rettypes = {},
            }, valuestype = {name = "T"},
        })
    end)

    it("separates keyword-named variables from modifiers and initializers", function()
        local tree = assert_parses_successfuly([[
            local: integer = 1
            const: integer = 2
            local const: integer = 3
            local const local: integer = 4
            do: integer = 5
            do end
        ]])
        assert.equal(6, #tree)
        assert.equal("local", tree[1].decl.name)
        assert.is_false(tree[1].islocal)
        assert.equal("const", tree[3].decl.name)
        assert.is_true(tree[3].islocal)
        assert.is_false(tree[3].isconst)
        assert.is_true(tree[4].isconst)
        assert.is_true(tree[6]._module_initializer)
    end)

    it("keeps generic owner, member, method, and bare-reference applications", function()
        local owner = assert_expression_ast("Box<|T|>.new(1)", {})
        assert.equal("T", owner.exp.var.exp._nominal_typeargs[1].name)
        assert.equal(0, #owner.typeargs)
        local call = assert_expression_ast("module.f<|T|>(1)", {})
        assert.equal("T", call.typeargs[1].name)
        assert.is_nil(call.exp._nominal_typeargs)
        local method = assert_expression_ast("x:m<|T|>", {})
        assert.equal("Ast.ExpMethodRef", method._tag)
        assert.equal("T", method._nominal_typeargs[1].name)
        assert_expression_ast('f<|T|>"text"', {_tag="Ast.ExpCall", typeargs={{name="T"}}})
    end)

    it("keeps vararg count distinct from greedy complete-expression spreads", function()
        assert_expression_ast("#... - 1", {op="-", lhs={_tag="Ast.ExpDotsLen"}})
        assert_expression_ast("#... ^ 2", {op="^", lhs={_tag="Ast.ExpDotsLen"}})
        assert_expression_ast("#...[1]", {op="#", exp={_tag="Ast.ExpDotsIndex"}})
        assert_expression_ast("...items + tail", {_tag="Ast.ExpSpread", exp={op="+"}})
        assert_expression_ast("... - 1", {_tag="Ast.ExpSpread", exp={op="-"}})
        assert_expression_ast("(...[1,2])", {_tag="Ast.ExpAdjust", exp={_tag="Ast.ExpSubset"}})
    end)

    it("does not allow removed field-name or fixed-array annotations", function()
        assert.falsy(parser.parse("old.titan", "record R field?: integer end"))
        for _, pair in ipairs({{"3", "count"}, {"3", "2"}, {"0", "0"}}) do
            assert_statements_syntax_error(
                "local a: foreign Item[" .. pair[1] .. "] = foreign Item.new_array(" .. pair[2] .. ")",
                "RBracketCArray")
        end
        assert_type_syntax_error("owned *(owned *Item)", "RParenTypelist")
    end)

    it("commits malformed explicit generics and validates trailing source", function()
        assert_expression_syntax_error("f<|T,|>()", "TypeArgument")
        assert_expression_syntax_error("f<|T", "RAngleTypeArgs")
        assert_program_syntax_error("function f() end @", "fail")
        assert_program_syntax_error("do end x = 1", "fail")
    end)

    it("folds a wide constructor with linear capture evaluation", function()
        local function measure(count)
            local fields = {}
            for i=1,count do fields[i] = "x" end
            local _, instructions = parse_under_instruction_budget(
                expression_test_program("{" .. table.concat(fields, ",") .. "}"), 2000000)
            return instructions
        end
        local small, large = measure(300), measure(600)
        assert.is_true(large < small * 2.5)
        assert.is_true(large > small)
    end)

    it("lowers a flat sequence of defers without copying or recursing over tails", function()
        local function measure(count)
            local source = "function f() " .. string.rep("defer release(); ", count) .. "end"
            local tree, instructions = parse_under_instruction_budget(source, 2000000)
            local stats, seen = tree[1].block.stats, 0
            while #stats > 0 do
                assert.equal(1, #stats)
                assert.equal("Ast.StatTry", stats[1]._tag)
                seen = seen + 1
                stats = stats[1].block.stats
            end
            assert.equal(count, seen)
            return instructions
        end
        local small, large = measure(200), measure(400)
        assert.is_true(large < small * 2.5)
        assert.is_true(large > small)
    end)

    it("keeps type-list capacity separate from written parameter and expression limits", function()
        local names = {}
        for i = 1, 251 do names[i] = "integer" end
        local list = table.concat(names, ",")
        local tree = assert_parses_successfuly("function f(): (" .. list .. ") end")
        assert.equal(251, #tree[1].rettypes)
        assert_type_ast("function(" .. list .. ")", {_tag="Ast.TypeFunction"})
    end)

    it("keeps foreign signatures in the raw single-result category", function()
        assert_program_syntax_error(
            "foreign function bad(): (int,int) return 1,2 end", "RParenTypelist")
        assert_program_syntax_error(
            "foreign function bad(): (...: int) end", "LParenType")
        assert_program_syntax_error(
            "foreign function bad(input: owned *Item): void end", "RParPList")
    end)

    it("keeps wide union synthesis in a constant number of capture results", function()
        local variants = {}
        for i = 1, 20000 do variants[i] = "variant" .. i .. "()" end
        local tree = assert_parses_successfuly("union Wide " .. table.concat(variants, " ") .. " end")
        assert.equal(20000, #tree[1].variants)
        assert.equal(20001, #tree)
        assert.equal("variant20000", tree[#tree].name)
    end)

    it("folds wide union payload and named case lists without capture-stack growth", function()
        local parts, bindings = {}, {}
        for i = 1, 1500 do
            parts[i] = "part" .. i .. ": integer"
            bindings[i] = "alias" .. i .. " = part" .. (1501 - i)
        end
        local tree = assert_parses_successfuly("union Wide item(" ..
            table.concat(parts, ",") .. ") end\n" ..
            "function f(x: Wide) case x when item{" ..
            table.concat(bindings, ",") .. "} then end end")
        assert.equal(1500, #tree[1].variants[1].parts)
        assert.equal(1500, #tree[2].params)
        assert.equal(1500, #tree[2].block.stats[1].exps[1].values)
        local arm = tree[3].block.stats[1].arms[1]
        assert.equal(1500, #arm.bindings)
        assert.equal("part1", arm.bindings[1500].part)
    end)

    it("does not retain dynamic lexer captures across wide flat constructors", function()
        local count = 40000
        local tree = assert_parses_successfuly("local values = {" ..
            string.rep("item,1,", count // 2 - 1) .. "item,1}")
        assert.equal(count, #tree[1].value.fields)
        assert.equal("Ast.ExpVar", tree[1].value.fields[1].exp._tag)
        assert.equal("Ast.ExpInteger", tree[1].value.fields[count].exp._tag)
    end)

    it("cleans per-parse state after ordinary-capture validation failures", function()
        local parameters = {}
        for i = 1, 101 do parameters[i] = "x" .. i .. ": integer" end
        local tree, err = parser.parse("wide.titan",
            "function f(" .. table.concat(parameters, ",") .. ") end")
        assert.is_false(tree)
        assert.equal("ListTooLong", err.label)
        assert.equal("wide.titan", err.loc.filename)
        tree, err = parser.parse("shape.titan", "local f: function(): (T,U)? = nil")
        assert.is_false(tree)
        assert.equal("OptionTypeList", err.label)
        tree = assert(parser.parse("recovered.titan", "local x = 1"))
        assert.equal("recovered.titan", tree[1].loc.filename)
    end)
end)

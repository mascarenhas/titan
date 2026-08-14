local parser = require 'titan-compiler.parser'
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

local function assert_is_subset(expected_ast, ast)
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
                'local c%d = foreign import "header%d.h"', i, i)
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
                decl = { name = "x", type = false, option = false } },
            { _tag = "Ast.StatBlock",
                stats = {
                    { _tag = "Ast.StatDecl",
                        decls = { { name = "y", type = false, option = false } } },
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

    it("can parse toplevel var declarations", function()
        assert_program_ast([[ local x=17 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = true,
                decl = { name = "x", type = false, option = false } }
        })

        assert_program_ast([[ y = 18 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = false,
                decl = { name = "y", type = false, option = false } }
        })

        assert_program_ast([[ local x?=17 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = true,
                decl = { name = "x", type = false, option = true } }
        })

        assert_program_ast([[ y? = 18 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = false,
                decl = { name = "y", type = false, option = true } }
        })

        assert_program_ast([[ local x?: integer =17 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = true,
                decl = { name = "x", type = {_tag = "Ast.TypeOption", basetype = {_tag = "Ast.TypeInteger"}}, option = false } }
        })

        assert_program_ast([[ y?: integer = 18 ]], {
            { _tag = "Ast.TopLevelVar",
                islocal = false,
                decl = { name = "y", type = {_tag = "Ast.TypeOption", basetype = {_tag = "Ast.TypeInteger"}}, option = false } }
        })
    end)

    it("can parse local var declarations", function()
        assert_statements_ast([[ local x=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = false, option = false } } }
        })

        assert_statements_ast([[ local x?=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = false, option = true } } }
        })

        assert_statements_ast([[ local x: integer=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = { _tag = "Ast.TypeInteger" }, option = false } } }
        })

        assert_statements_ast([[ local x?: integer=17 ]], {
            { _tag = "Ast.StatDecl",
                decls = { { name = "x", type = { _tag = "Ast.TypeOption", basetype = {_tag = "Ast.TypeInteger"} }, option = false } } }
        })
    end)

    it("parses constructor-initialized fixed and borrowed C array locals",
    function()
        assert_statements_ast([[
            local storage: ffi.Item[3] = ffi.Item.new_array(3)
            local borrowed: ffi.Item[] = ffi.Item.new_array(count)
            local zero: ffi.Item[0] = ffi.Item.new_array(0)
            local negative: ffi.Item[-2] = ffi.Item.new_array(2)
            local first: ffi.Item[1], second: ffi.Other[] = a, b
        ]], {
            { _tag = "Ast.StatDecl", decls = {
                { _tag = "Ast.Decl", name = "storage", type = {
                    _tag = "Ast.TypeCArray",
                    base = {
                        _tag = "Ast.TypeQualName",
                        module = "ffi",
                        name = "Item",
                    },
                    length = { _tag = "Ast.ExpInteger", value = 3 },
                }, option = false },
            }, exps = { { _tag = "Ast.ExpCall" } } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "borrowed", type = {
                    _tag = "Ast.TypeCArray",
                    base = { _tag = "Ast.TypeQualName", name = "Item" },
                    length = false,
                } },
            }, exps = { { _tag = "Ast.ExpCall" } } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "zero", type = {
                    _tag = "Ast.TypeCArray",
                    length = { _tag = "Ast.ExpInteger", value = 0 },
                } },
            } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "negative", type = {
                    _tag = "Ast.TypeCArray",
                    length = { _tag = "Ast.ExpInteger", value = -2 },
                } },
            } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "first", type = { _tag = "Ast.TypeCArray" } },
                { name = "second", type = {
                    _tag = "Ast.TypeCArray", length = false,
                } },
            }, exps = {
                { _tag = "Ast.ExpVar" }, { _tag = "Ast.ExpVar" },
            } },
        })

        -- Zero and negative integer tokens reach the checker so it can issue
        -- the semantic positive-extent diagnostic. Keep the sign position on
        -- the literal node for that diagnostic.
        local source = "function f() local storage: ffi.Item[-8] = source end"
        local program = assert(parser.parse("automatic.titan", source))
        local arraytype = program[1].block.stats[1].decls[1].type
        assert.same({
            filename = "automatic.titan",
            line = 1,
            col = 29,
        }, arraytype.loc)
        assert.same(arraytype.loc, arraytype.base.loc)
        assert.same({
            filename = "automatic.titan",
            line = 1,
            col = 38,
        }, arraytype.length.loc)
    end)

    it("retains ordinary initialized qualified local declarations", function()
        assert_statements_ast([[
            local object: ffi.Object = source
            local first: ffi.Object, second: ffi.Other = a, b
        ]], {
            { _tag = "Ast.StatDecl", decls = {
                { name = "object", type = {
                    _tag = "Ast.TypeQualName",
                    module = "ffi",
                    name = "Object",
                } },
            }, exps = { { _tag = "Ast.ExpVar" } } },
            { _tag = "Ast.StatDecl", decls = {
                { name = "first", type = { _tag = "Ast.TypeQualName" } },
                { name = "second", type = { _tag = "Ast.TypeQualName" } },
            }, exps = {
                { _tag = "Ast.ExpVar" },
                { _tag = "Ast.ExpVar" },
            } },
        })
    end)

    it("rejects malformed constructor-local C array extents precisely",
    function()
        for _, extent in ipairs({ "count", "3.0", "-2.5", "1 + 2" }) do
            assert_statements_syntax_error(
                "local storage: ffi.Item[" .. extent .. "] = source",
                "RBracketCArray")
        end
        assert_statements_syntax_error(
            "local storage: ffi.Item[3 = source", "RBracketCArray")
    end)

    it("keeps C array targets out of general type positions", function()
        local programs = {
            "function f(x: ffi.Item[3]) end",
            "function f(): ffi.Item[3] end",
            "type Items = ffi.Item[3]",
            "record R item: ffi.Item[3] end",
            "function f() local x = y as ffi.Item[3] end",
            "function f() local items: ffi.Item?[3] = source end",
            "function f() local items: Item[3] = source end",
            "function f() local items: integer[3] = source end",
        }
        for _, program in ipairs(programs) do
            assert_program_syntax_error(program, "CArrayOnlyAutomatic")
        end

        for _, declaration in ipairs({
            "local object: ffi.Item",
            "local fixed: ffi.Item[3]",
            "local borrowed: ffi.Item[]",
            "local optional: ffi.Item[3]? = source",
            "local nested: ffi.Item[3][4] = source",
        }) do
            assert_statements_syntax_error(declaration, "AssignLocal")
        end
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
            local function fB(x:int): nil
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
            local function fC(x:int, y:int): nil
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

    it("parses foreign declarations and foreign function-pointer types",
    function()
        assert_program_ast([[
            foreign function notify(): ()
                return
            end

            foreign function apply(
                item: *c.Item,
                callback: foreign (c.int) -> c.int
            ): c.int
                return callback(0)
            end

            local type Nested =
                foreign (foreign (c.int) -> c.int) -> ()
            local type RejectedShapes =
                foreign (c.int, ...: c.int) -> (c.int, ...: c.int)
        ]], {
            { _tag = "Ast.TopLevelForeignFunc",
                name = "notify",
                params = {},
                rettypes = {},
                flexrettype = false,
                block = { _tag = "Ast.StatBlock", stats = {
                    { _tag = "Ast.StatReturn", exps = {} },
                } } },
            { _tag = "Ast.TopLevelForeignFunc",
                name = "apply",
                params = {
                    { _tag = "Ast.Decl", name = "item", type = {
                        _tag = "Ast.TypeCPointer",
                        subtype = { _tag = "Ast.TypeQualName",
                            module = "c", name = "Item" },
                    } },
                    { _tag = "Ast.Decl", name = "callback", type = {
                        _tag = "Ast.TypeForeignFunction",
                        argtypes = { { _tag = "Ast.TypeQualName",
                            module = "c", name = "int" } },
                        rettypes = { { _tag = "Ast.TypeQualName",
                            module = "c", name = "int" } },
                        varargtype = false,
                        flexrettype = false,
                    } },
                },
                rettypes = { { _tag = "Ast.TypeQualName",
                    module = "c", name = "int" } } },
            { _tag = "Ast.TopLevelTypeAlias", name = "Nested", type = {
                _tag = "Ast.TypeForeignFunction",
                argtypes = { { _tag = "Ast.TypeForeignFunction" } },
                rettypes = {},
            } },
            { _tag = "Ast.TopLevelTypeAlias", name = "RejectedShapes",
                type = {
                    _tag = "Ast.TypeForeignFunction",
                    varargtype = { _tag = "Ast.TypeQualName" },
                    rettypes = { { _tag = "Ast.TypeQualName" } },
                    flexrettype = { _tag = "Ast.TypeQualName" },
                } },
        })
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
            function Record:fB(x:int): nil
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
            function Record:fC(x:int, y:int): nil
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
            function Record.fB(x:int): nil
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
              flexrettype = false },
            { _tag = "Ast.TopLevelFunc", name = "bar", rettypes = {},
              flexrettype = false },
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
                                    { _tag = "Ast.Decl", name = "x", type = false },
                                },
                                rettypes = false,
                                flexrettype = false,
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
                                flexrettype = false },
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
                                    { _tag = "Ast.Decl", name = "a", type = false },
                                    { _tag = "Ast.Decl", name = "b" },
                                    { _tag = "Ast.Decl", name = "c", type = false },
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
                              flexrettype = false },
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

    it("can parse qualified types", function()
        assert_type_ast("foo.bar", { _tag = "Ast.TypeQualName", module = "foo", name = "bar" } )
    end)

    it("marks Titan-keyword spellings only in contextual C name positions",
    function()
        assert_type_ast("c.type", {
            _tag = "Ast.TypeQualName",
            module = "c",
            name = "type",
            _contextual_c_name = true,
        })
        assert_type_ast("c.when", {
            _tag = "Ast.TypeQualName",
            module = "c",
            name = "when",
            _contextual_c_name = true,
        })
        assert_type_ast("c.interface", {
            _tag = "Ast.TypeQualName",
            module = "c",
            name = "interface",
            _contextual_c_name = true,
        })
        assert_expression_ast("c.when", {
            _tag = "Ast.ExpVar",
            var = {
                _tag = "Ast.VarDot",
                name = "when",
                _contextual_c_name = true,
            },
        })
        assert_expression_ast("c.repeat", {
            _tag = "Ast.ExpVar",
            var = {
                _tag = "Ast.VarDot",
                name = "repeat",
                _contextual_c_name = true,
            },
        })
        assert_expression_ast("c.interface", {
            _tag = "Ast.ExpVar",
            var = {
                _tag = "Ast.VarDot",
                name = "interface",
                _contextual_c_name = true,
            },
        })

        local ast = assert_parses_successfuly("local x: c.member = c.member")
        assert.is_nil(ast[1].decl.type._contextual_c_name)
        assert.is_nil(ast[1].value.var._contextual_c_name)

        for _, source in ipairs({
            "local when = 1",
            "function when(): nil end",
            "function R:when(): nil end",
            "function R.when(): nil end",
            "record R when: integer end",
            "union U when end",
            "function interface(): nil end",
            "record R interface: integer end",
        }) do
            local rejected = parser.parse("(parser_spec)", source)
            assert.falsy(rejected)
        end
    end)

    it("can parse scalar and counted owned C types", function()
        assert_type_ast("owned *ffi.Item", {
            _tag = "Ast.TypeCOwned",
            subtype = {
                _tag = "Ast.TypeQualName",
                module = "ffi",
                name = "Item",
            },
            count = false,
        })
        assert_type_ast("owned ffi.Item[]", {
            _tag = "Ast.TypeCOwned",
            subtype = {
                _tag = "Ast.TypeQualName",
                module = "ffi",
                name = "Item",
            },
            count = true,
        })
        assert_type_ast("owned **ffi.Item", {
            _tag = "Ast.TypeCOwned",
            subtype = {
                _tag = "Ast.TypeCPointer",
                subtype = {
                    _tag = "Ast.TypeQualName",
                    module = "ffi",
                    name = "Item",
                },
                const = false,
            },
            count = false,
        })
        assert_type_ast("owned *ffi.Item[]", {
            _tag = "Ast.TypeCOwned",
            subtype = {
                _tag = "Ast.TypeCPointer",
                subtype = {
                    _tag = "Ast.TypeQualName",
                    module = "ffi",
                    name = "Item",
                },
                const = false,
            },
            count = true,
        })
    end)

    it("applies the option suffix to the complete owned C type", function()
        assert_type_ast("owned *ffi.Item?", {
            _tag = "Ast.TypeOption",
            basetype = {
                _tag = "Ast.TypeCOwned",
                subtype = {
                    _tag = "Ast.TypeQualName",
                    module = "ffi",
                    name = "Item",
                },
                count = false,
            },
        })
        assert_type_ast("owned ffi.Item[]?", {
            _tag = "Ast.TypeOption",
            basetype = {
                _tag = "Ast.TypeCOwned",
                subtype = {
                    _tag = "Ast.TypeQualName",
                    module = "ffi",
                    name = "Item",
                },
                count = true,
            },
        })
    end)

    it("reports malformed owned C type shapes at the owned production",
    function()
        assert_type_syntax_error("owned ffi.Item", "COwnedShape")
        assert_type_syntax_error("owned *", "OwnedPayload")
        assert_type_syntax_error("owned ffi.Item[", "RBracketCOwned")
        assert_type_syntax_error("owned ffi.Item[4]", "RBracketCOwned")
    end)

    it("retains owned type source locations", function()
        local source =
            "local x: owned ffi.Item[]? = nil"
        local program = assert(parser.parse("owners.titan", source))
        local option = program[1].decl.type
        local owner = option.basetype
        assert.same({
            filename = "owners.titan",
            line = 1,
            col = 10,
        }, owner.loc)
        assert.same({
            filename = "owners.titan",
            line = 1,
            col = 16,
        }, owner.subtype.loc)
    end)

    it("can parse array types", function()
        assert_type_ast("{int}",
            { _tag = "Ast.TypeArray", subtype =
                {_tag = "Ast.TypeName", name = "int" } } )

        assert_type_ast("{{int}}",
            { _tag = "Ast.TypeArray", subtype =
                { _tag = "Ast.TypeArray", subtype =
                    {_tag = "Ast.TypeName", name = "int" } } } )
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

    describe("can parse generic type applications", function()
        it("retains direct and qualified applications with nested closers",
        function()
            assert_type_ast("Pair<integer, string>", {
                _tag = "Ast.TypeName",
                name = "Pair",
                typeargs = {
                    { _tag = "Ast.TypeInteger" },
                    { _tag = "Ast.TypeString" },
                },
            })
            assert_type_ast("mod.Outer<mod.Inner<T>>", {
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
            assert_type_ast("Pair<T, {mod.Item}>?", {
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
            assert_type_ast("() -> ()",
                { _tag = "Ast.TypeFunction",
                    argtypes = { },
                    rettypes = { } } )
        end)

        it("with parameter lists of length = 1", function()
            assert_type_ast("(a) -> (b)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "a" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "b" } } } )
        end)

        it("with parameter lists of length >= 2 ", function()
            assert_type_ast("(a,b) -> (c,d,e)",
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

        it("without the optional parenthesis", function()
            assert_type_ast("a -> b",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeName", name = "a" } },
                    rettypes = { { _tag = "Ast.TypeName", name = "b" } } } )
        end)


        it("and -> is right associative", function()
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

            assert_type_ast("a -> b -> c",   ast1)
            assert_type_ast("a -> (b -> c)", ast1)
            assert_type_ast("(a -> b) -> c", ast2)
        end)

        it("and '->' has higher precedence than ','", function()
            assert_type_ast("(a, b -> c, d) -> e",
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
              elsestat = false }
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
                elsestat = false }
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
        it("parses one or more when arms, bindings, and else", function()
            assert_statements_ast([[
                case msg
                when quit then
                    stop()
                when move: delta then
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
                            binding = false,
                            block = { _tag = "Ast.StatBlock" },
                        },
                        {
                            _tag = "Ast.CaseArm",
                            name = "move",
                            binding = {
                                _tag = "Ast.Decl",
                                name = "delta",
                                type = false,
                                option = false,
                            },
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
                when first then
                    defer cleanup_body()
                    body()
                catch
                    defer cleanup_catch()
                    recover()
                when second then
                    if ready then
                        nested()
                    end
                when third then
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
                        when item then
                            case inner
                            when done then
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
                    when item then
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

    it("requires lhs and rhs of local variable declaration", function()
        assert_statements_syntax_error([[
            local  = 10
        ]], "DeclLocal")
        assert_statements_syntax_error([[
            local x, = 10, 20
        ]], "DeclLocal")
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
              decl = { _tag = "Ast.Decl", name = "i", type = false },
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
              decls = {{ _tag = "Ast.Decl", name = "x", type = false }},
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

    it("allows Titan keywords only as named argument labels", function()
        assert_expression_ast([[ f{ repeat = 1 } ]], {
            _tag = "Ast.ExpCall",
            args = { _tag = "Ast.ArgsNamedFunc", fields = {
                { name = "repeat", exp = { value = 1 } },
            } },
        })
        assert_expression_ast([[ f{ when = 2 } ]], {
            _tag = "Ast.ExpCall",
            args = { _tag = "Ast.ArgsNamedFunc", fields = {
                { name = "when", exp = { value = 2 } },
            } },
        })
        assert_expression_ast([[ f{ interface = 3 } ]], {
            _tag = "Ast.ExpCall",
            args = { _tag = "Ast.ArgsNamedFunc", fields = {
                { name = "interface", exp = { value = 3 } },
            } },
        })

        assert_program_syntax_error([[
            function repeat(): nil end
        ]], "NameFunc")
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

            assert_expression_ast("f < Outer<Inner<T>> > (x)", {
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
            assert_expression_ast("make<integer>{item = x}", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeInteger" } },
                args = {
                    _tag = "Ast.ArgsNamedFunc",
                    fields = { { name = "item", exp = { var = { name = "x" } } } },
                },
            })
            assert_expression_ast("object:map<string>(x)", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = { _tag = "Ast.ArgsMethod", method = "map" },
            })
            assert_expression_ast("object:map<string>{item = x}", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = { _tag = "Ast.ArgsNamedMethod", method = "map" },
            })
            assert_expression_ast("Pair<integer, string>.new(1, 'one')", {
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
            assert_expression_ast("library.Pair<T>.from<U>{item = x}", {
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
            assert_expression_ast("make<string> 'item'", {
                _tag = "Ast.ExpCall",
                typeargs = { { _tag = "Ast.TypeString" } },
                args = {
                    _tag = "Ast.ArgsFunc",
                    args = { { _tag = "Ast.ExpString", value = "item" } },
                },
            })
            assert_expression_ast("object:map<string> 'item'", {
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
            assert_expression_ast("Box<Outer<Inner<T>>>.make()", {
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
            assert_expression_ast("a < b > (c)", {
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
            { name = false, exp = { value = 1 } },
            { name = false, exp = { value = 2 } },
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

    it("only allows call expressions as statements", function()
        -- Currently the error messages mention something else

        assert_statements_syntax_error([[
            (f)
        ]], "ExpStat")

        assert_statements_syntax_error([[
            1 + 1
        ]], "ExpStat")
    end)

    it("can parse import", function ()
        assert_program_ast([[ local foo = import "module.foo" ]], {
            { _tag = "Ast.TopLevelImport", localname = "foo", modname = "module.foo" },
        })
    end)

    it("desugars standard-library short imports to qualified modules",
       function()
        local names = {
            "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
            "url", "http", "os", "peg", "string", "test",
        }
        for _, name in ipairs(names) do
            assert_program_ast(
                'local library = import "' .. name .. '"', {
                    {
                        _tag = "Ast.TopLevelImport",
                        localname = "library",
                        modname = "titan." .. name,
                    },
                })
            assert_program_ast(
                'local library = import "titan.' .. name .. '"', {
                    {
                        _tag = "Ast.TopLevelImport",
                        localname = "library",
                        modname = "titan." .. name,
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
                handle?: owned *ffi.Handle
                local bytes?: owned ffi.Byte[]
            end
        ]], {
            { _tag = "Ast.TopLevelRecord",
              name = "Owners",
              fields = {
                { name = "handle", type = {
                    _tag = "Ast.TypeOption",
                    basetype = {
                        _tag = "Ast.TypeCOwned",
                        count = false,
                    },
                } },
                { name = "bytes", islocal = true, type = {
                    _tag = "Ast.TypeOption",
                    basetype = {
                        _tag = "Ast.TypeCOwned",
                        count = true,
                    },
                } } } },
        })
    end)

    it("parses unions and synthesizes adjacent positional constructors",
    function()
        local source = [[
            union Message
                quit;
                move: Message
                local nil_payload: nil;
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
                        payload = false,
                    },
                    {
                        _tag = "Ast.UnionVariant",
                        name = "move",
                        payload = {
                            _tag = "Ast.TypeName",
                            name = "Message",
                        },
                    },
                    {
                        _tag = "Ast.UnionVariant",
                        islocal = true,
                        name = "nil_payload",
                        payload = { _tag = "Ast.TypeNil" },
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
                                    value = false,
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
                        name = "__union_payload",
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
                                    value = {
                                        _tag = "Ast.ExpVar",
                                        var = {
                                            _tag = "Ast.VarName",
                                            name = "__union_payload",
                                        },
                                    },
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

    it("makes every constructor of a local union local", function()
        local ast = assert_parses_successfuly([[
            local union Hidden
                empty
                payload: integer
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
            when item then
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
                        flexrettype = false,
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
                        flexrettype = false,
                    },
                    {
                        _tag = "Ast.InterfaceMethod",
                        name = "flush",
                        params = {},
                        rettypes = {},
                        flexrettype = false,
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
                        flexrettype = false,
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
                                name = false,
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

    it("rejects invalid interface declaration and member forms", function()
        local cases = {
            {
                [[interface Empty
end]],
                "MethodInterface",
            },
            {
                [[local interface Local
function f()
end]],
                "LocalInterface",
            },
            {
                [[interface I
local function f()
end]],
                "LocalInterfaceMethod",
            },
            {
                [[interface I
function I:f()
end]],
                "LParInterfaceMethod",
            },
            {
                [[interface I
function f(): integer
return 1
end
end]],
                "MemberInterface",
            },
            {
                [[interface I
function f()
value: integer
end]],
                "MemberInterface",
            },
            {
                [[interface I
function I.make()
end]],
                "LParInterfaceMethod",
            },
            {
                [[interface I
function I.new()
end]],
                "LParInterfaceMethod",
            },
            {
                [[function outer(): nil
interface Nested
function f()
end
end]],
                "NestedInterface",
            },
            {
                [[interface
function f()
end]],
                "NameInterface",
            },
            {
                [[interface I
function ()
end]],
                "NameInterfaceMethod",
            },
            {
                [[interface I
function f: nil
end]],
                "LParInterfaceMethod",
            },
            {
                [[interface I
function f(value: integer: nil
end]],
                "RParInterfaceMethod",
            },
            {
                [[interface I
function f():
end]],
                "TypeInterfaceMethod",
            },
            {
                [[interface I
function f()]],
                "EndInterface",
            },
        }

        for _, case in ipairs(cases) do
            assert_program_syntax_error(case[1], case[2])
        end

        -- With no body, the first `end` necessarily closes the interface.
        -- A second one therefore proves that a per-method `end` is not
        -- silently accepted as part of the interface declaration.
        local parsed = parser.parse("(parser_spec)", [[
            interface I
                function f()
                end
            end
        ]])
        assert.falsy(parsed)
    end)

    describe("can parse generic declarations", function()
        it("retains owner and callable binders in their source scopes",
        function()
            local program = assert_parses_successfuly([[
                record Pair<T, U: api.Show<T>>
                    first: T
                    second: U
                end

                union Result<T, E>
                    ok: T
                    error: E
                end

                interface Stack<E>
                    function push<R: Stack<E>>(item: E): R
                end

                function id<T>(x: T): T return x end
                function Pair:map<V>(f: (T) -> V): Pair<V, U>
                    return nil
                end
                function Pair.make<V>(item: V): Pair<V, V>
                    return nil
                end
            ]])

            assert_is_subset({
                {
                    _tag = "Ast.TopLevelRecord",
                    name = "Pair",
                    typeparams = {
                        { _tag = "Ast.TypeParam", name = "T", constraint = false },
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
                        { name = "T", constraint = false },
                        { name = "E", constraint = false },
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
                    typeparams = { { name = "E", constraint = false } },
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
                    typeparams = { { name = "T", constraint = false } },
                },
                {
                    _tag = "Ast.TopLevelMethod",
                    class = "Pair",
                    name = "map",
                    typeparams = { { name = "V", constraint = false } },
                },
                {
                    _tag = "Ast.TopLevelStatic",
                    class = "Pair",
                    name = "make",
                    typeparams = { { name = "V", constraint = false } },
                },
            }, program)

            assert.are.equal(9, #program)
        end)

        it("records empty binder lists on existing declarations", function()
            local program = assert_parses_successfuly([[
                record Plain item: integer end
                union Maybe none end
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

    it("can parse cast and type-test expressions", function()
        assert_expression_ast([[ foo as integer ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ a.b[1].c as integer ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ foo as { integer } ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeArray" } })
        assert_expression_ast([[ 2 + foo as integer ]],
            { rhs = { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } }})
        assert_expression_ast([[ #... as value ]],
            { _tag = "Ast.ExpCast",
                exp = { _tag = "Ast.ExpUnop", op = "#",
                    exp = { _tag = "Ast.ExpDots" } },
                target = { _tag = "Ast.TypeValue" } })

        -- A local two-component variant-looking target remains syntactically a
        -- qualified type so the checker can issue the semantic diagnostic.
        assert_expression_ast([[ x as Message.move ]], {
            _tag = "Ast.ExpCast",
            target = {
                _tag = "Ast.TypeQualName",
                module = "Message",
                name = "move",
            },
        })
        assert_expression_ast([[ x is Message.move ]], {
            _tag = "Ast.ExpIs",
            target = {
                _tag = "Ast.TypeQualName",
                module = "Message",
                name = "move",
            },
        })

        -- Type syntax has only one qualifier. Imported variants require three
        -- components and therefore never become a type target.
        for _, op in ipairs({ "as", "is" }) do
            local program = expression_test_program(
                "x " .. op .. " m.Message.move")
            local ast = parser.parse("(parser_spec)", program)
            assert.falsy(ast)
        end

        assert_expression_ast([[ foo is integer ]],
            { _tag = "Ast.ExpIs", exp = { _tag = "Ast.ExpVar" },
                target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ foo is (integer) -> integer ]],
            { _tag = "Ast.ExpIs", target = {
                _tag = "Ast.TypeFunction",
                argtypes = { { _tag = "Ast.TypeInteger" } },
                rettypes = { { _tag = "Ast.TypeInteger" } } } })
        assert_expression_ast([[ 2 + foo is integer ]],
            { _tag = "Ast.ExpBinop",
                rhs = { _tag = "Ast.ExpIs",
                    exp = { _tag = "Ast.ExpVar" },
                    target = { _tag = "Ast.TypeInteger" } } })
        assert_expression_ast([[ -foo is integer ]],
            { _tag = "Ast.ExpIs",
                exp = { _tag = "Ast.ExpUnop", op = "-",
                    exp = { _tag = "Ast.ExpVar" } },
                target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ foo ^ 2 is integer ]],
            { _tag = "Ast.ExpBinop", op = "^",
                rhs = { _tag = "Ast.ExpIs",
                    exp = { _tag = "Ast.ExpInteger", value = 2 },
                    target = { _tag = "Ast.TypeInteger" } } })
        assert_expression_ast([[ (foo ^ 2) is integer ]],
            { _tag = "Ast.ExpIs",
                exp = { _tag = "Ast.ExpBinop", op = "^" },
                target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ foo ^ 2 as integer ]],
            { _tag = "Ast.ExpBinop", op = "^",
                rhs = { _tag = "Ast.ExpCast",
                    exp = { _tag = "Ast.ExpInteger", value = 2 },
                    target = { _tag = "Ast.TypeInteger" } } })
        assert_expression_ast([[ (foo as value) is integer ]],
            { _tag = "Ast.ExpIs",
                exp = { _tag = "Ast.ExpCast",
                    target = { _tag = "Ast.TypeValue" } },
                target = { _tag = "Ast.TypeInteger" } })
        assert_expression_syntax_error([[ foo is ]], "IsMissingType")
        assert_expression_syntax_error(
            [[ foo is integer ^ 2 ]], "EndFunc")
    end)

    it("does not allow parentheses in the LHS of an assignment", function()
        assert_statements_syntax_error([[ local (x) = 42 ]], "DeclLocal")
        assert_statements_syntax_error([[ (x) = 42 ]], "AssignNotLValue")
    end)

    it("does not allow identifiers that are type names", function()
        assert_program_syntax_error([[
            function integer()
            end
        ]], "NameFunc")

        assert_program_syntax_error([[
            function f()
                local integer: integer = 10
            end
        ]], "DeclLocal")

        assert_program_syntax_error([[
            function type()
            end
        ]], "NameFunc")
    end)

    it("doesn't allow using a primitive type as a record", function()
        assert_expression_syntax_error("integer.new(10)", "ExpAssign")
    end)

    it("reports source locations for union and case labels", function()
        local _, union_err = parser.parse("new-errors.titan", [[
union U
end]])
        assert.are.equal("VariantUnion", union_err.label)
        assert.are.same({
            filename = "new-errors.titan",
            line = 2,
            col = 1,
        }, union_err.loc)

        local _, case_err = parser.parse("new-errors.titan", [[
function f(): nil
case msg
when item: then
end
end]])
        assert.are.equal("NameCaseBinding", case_err.label)
        assert.are.same({
            filename = "new-errors.titan",
            line = 3,
            col = 12,
        }, case_err.loc)
    end)

    describe("reports focused generic syntax errors", function()
        it("labels malformed declaration binders and type applications",
        function()
            assert_program_syntax_error("record Empty<> end", "NameTypeParam")
            assert_program_syntax_error(
                "record Trailing<T,> item: T end", "NameTypeParam")
            assert_program_syntax_error(
                "record Missing<T:> item: T end", "TypeParamConstraint")
            assert_program_syntax_error(
                "record Unclosed<T item: T end", "RAngleTypeParams")

            assert_type_syntax_error("Pair<>", "TypeArgument")
            assert_type_syntax_error("Pair<T,>", "TypeArgument")
            assert_type_syntax_error("Pair<T", "RAngleTypeArgs")
        end)

        it("rejects binders on foreign functions, lambdas, and aliases",
        function()
            assert_program_syntax_error([[
                foreign function callback<T>(item: T): T return item end
            ]], "GenericForeignFunc")
            assert_program_syntax_error([[
                function outer(): nil
                    local callback = function<T>(item: T): T return item end
                end
            ]], "GenericLambda")
            assert_program_syntax_error(
                "type Identity<T> = T", "GenericTypeAlias")
        end)

        it("does not commit an incomplete ambiguous call suffix", function()
            assert_expression_syntax_error("f<T,>(x)", "ExpExpList")
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

    it("uses specific error labels for some errors", function()

        assert_program_syntax_error([[
            function () : int
            end
        ]], "NameFunc")

        assert_program_syntax_error([[
            function Record:() : int
            end
        ]], "NameMethod")

        assert_program_syntax_error([[
            function foo : int
            end
        ]], "LParPList")

        assert_program_syntax_error([[
            function foo ( : int
            end
        ]], "RParPList")

        assert_program_syntax_error([[
            function foo () :
                local x = 3
            end
        ]], "TypeFunc")

        assert_program_syntax_error([[
            function foo () : int
              local x = 3
              return x
        ]], "EndFunc")

        assert_program_syntax_error([[
            function foo(x, y) : int
            end
        ]], "ParamSemicolon")

        assert_program_syntax_error([[
            x 3
        ]], "AssignVar")

        assert_program_syntax_error([[
            x =
        ]], "ExpVarDec")

        assert_program_syntax_error([[
            type = integer
        ]], "NameTypeAlias")

        assert_program_syntax_error([[
            type Count integer
        ]], "AssignTypeAlias")

        assert_program_syntax_error([[
            type Count =
        ]], "TypeTypeAlias")

        assert_program_syntax_error([[
            record
        ]], "NameRecord")

        assert_program_syntax_error([[
            record A
                x : int
        ]], "EndRecord")

        assert_program_syntax_error([[
            union
        ]], "NameUnion")

        assert_program_syntax_error([[
            union Empty
            end
        ]], "VariantUnion")

        assert_program_syntax_error([[
            union U
                local : integer
            end
        ]], "NameUnionVariant")

        assert_program_syntax_error([[
            union U
                payload:
            end
        ]], "TypeUnionVariant")

        assert_program_syntax_error([[
            union U
                item
        ]], "EndUnion")

        assert_program_syntax_error([[
            local = import "bola"
        ]], "NameImport")

        assert_program_syntax_error([[
            local bola = import ()
        ]], "StringLParImport")

        assert_program_syntax_error([[
            local bola = import ('bola'
        ]], "RParImport")

        assert_program_syntax_error([[
            local bola = import
        ]], "StringImport")

        assert_program_syntax_error([[
            function foo (a:int, ) : int
            end
        ]], "DeclParList")

        assert_program_syntax_error([[
            function foo (a: ) : int
            end
        ]], "TypeDecl")


        assert_type_syntax_error([[ {} ]], "TypeType")

        assert_type_syntax_error([[ {int ]], "RCurlyType")

        assert_type_syntax_error([[ (a,,,) -> b ]], "TypelistType")

        assert_type_syntax_error([[ (a, b -> b  ]], "RParenTypelist")

        assert_type_syntax_error([[ (a, b) -> = nil ]], "TypeReturnTypes")

        assert_type_syntax_error([[ foo. ]], "QualName")

        assert_program_syntax_error([[
            record A
                x  int
            end
        ]], "ColonRecordField")

        assert_program_syntax_error([[
            record A
                x : function
            end
        ]], "TypeRecordField")

        assert_program_syntax_error([[
            function f ( x : int) : string
                do
                return "42"
        ]], "EndBlock")

        assert_statements_syntax_error([[
            while do
                x = x - 1
            end
        ]], "ExpWhile")

        assert_statements_syntax_error([[
            case
        ]], "ExpCase")

        assert_statements_syntax_error([[
            case msg
            end
        ]], "WhenCase")

        assert_statements_syntax_error([[
            case msg
            when then
            end
        ]], "NameCaseVariant")

        assert_statements_syntax_error([[
            case msg
            when payload:
            then
            end
        ]], "NameCaseBinding")

        assert_statements_syntax_error([[
            case msg
            when payload
            end
        ]], "ThenCase")

        assert_program_syntax_error([[
            function f(): nil
                case msg
                when payload then
        ]], "EndCase")

        assert_statements_syntax_error([[
            while x > 3
                x = x - 1
            end
        ]], "DoWhile")

        assert_statements_syntax_error([[
            while x > 3 do
                x = x - 1
                return 42
            return 41
        ]], "EndWhile")

        assert_statements_syntax_error([[
            repeat
                x = x - 1
            end
        ]], "UntilRepeat")

        assert_statements_syntax_error([[
            repeat
                x = x - 1
            until
        ]], "ExpRepeat")

        assert_statements_syntax_error([[
            if then
                x = x - 1
            end
        ]], "ExpIf")

        assert_statements_syntax_error([[
            if x > 10
                x = x - 1
            end
        ]], "ThenIf")

        assert_statements_syntax_error([[
            if x > 10 then
                x = x - 1
                return 42
            return 41
        ]], "EndIf")

        assert_statements_syntax_error([[
            for = 1, 10 do
            end
        ]], "DeclFor")

        assert_statements_syntax_error([[
            for x  1, 10 do
            end
        ]], "AssignFor")

        assert_statements_syntax_error([[
            for x = , 10 do
            end
        ]], "Exp1For")

        assert_statements_syntax_error([[
            for x = 1 10 do
            end
        ]], "CommaFor")

        assert_statements_syntax_error([[
            for x = 1, do
            end
        ]], "Exp2For")

        assert_statements_syntax_error([[
            for x = 1, 10, do
            end
        ]], "Exp3For")

        assert_statements_syntax_error([[
            for x = 1, 10, 1
            end
        ]], "DoFor")

        assert_statements_syntax_error([[
            for x = 1, 10, 1 do
                return 42
            return 41
        ]], "EndFor")

        assert_statements_syntax_error([[
            for x, y = 1, 2 do
            end
        ]], "InFor")

        assert_statements_syntax_error([[
            for x in do
            end
        ]], "ExpForIn")

        assert_statements_syntax_error([[
            for x, in iter do
            end
        ]], "DeclParList")

        assert_statements_syntax_error([[
            for x in iter
            end
        ]], "DoForIn")

        assert_statements_syntax_error([[
            for x in iter do
                return 42
            return 41
        ]], "EndForIn")

        assert_statements_syntax_error([[
            local = 3
        ]], "DeclLocal")

        assert_statements_syntax_error([[
            local x  3
        ]], "AssignLocal")

        assert_statements_syntax_error([[
            local x =
        ]], "ExpLocal")

        assert_statements_syntax_error([[
            x
        ]], "AssignAssign")

        assert_statements_syntax_error([[
            x =
        ]], "ExpAssign")

        assert_statements_syntax_error([[
            if x > 1 then
                x = x - 1
            elseif then
            end
        ]], "ExpElseIf")

        assert_statements_syntax_error([[
            if x > 1 then
                x = x - 1
            elseif x > 0
            end
        ]], "ThenElseIf")

        assert_expression_syntax_error([[ 1 + ]], "OpExp")

        assert_expression_syntax_error([[ obj:() ]], "NameColonExpSuf")

        assert_expression_syntax_error([[ y[] ]], "ExpExpSuf")

        assert_expression_syntax_error([[ y[1 ]], "RBracketExpSuf")

        assert_expression_syntax_error([[ y.() ]], "NameDotExpSuf")

        assert_expression_syntax_error([[ () ]], "ExpSimpleExp")

        assert_expression_syntax_error([[ (42 ]], "RParSimpleExp")

        assert_expression_syntax_error([[ f(42 ]], "RParFuncArgs")

        assert_expression_syntax_error([[ f(42,) ]], "ExpExpList")

        assert_expression_syntax_error([[ y({42) ]], "RCurlyInitList")

        assert_expression_syntax_error([[ y({42,,}) ]], "ExpFieldList")

        assert_expression_syntax_error([[ foo as ]], "CastMissingType")
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
                        { _tag = "Ast.Decl", name = false,
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
                        { _tag = "Ast.Decl", name = false,
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
                        { _tag = "Ast.Decl", name = false,
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
                    flexrettype = false,
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
                                        { _tag = "Ast.Decl", name = false,
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
            -- The vararg Decl carries name == false AND type == false.
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
                                          type = false },
                                        { _tag = "Ast.Decl", name = false,
                                          type = false },
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
                                        { _tag = "Ast.Decl", name = false,
                                          type = false },
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
                                        { _tag = "Ast.Decl", name = false,
                                          type = false },
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
                                        { _tag = "Ast.Decl", name = false,
                                          type = { _tag = "Ast.TypeInteger" } },
                                    } } } } } } },
            })
        end)

        it("rejects an untyped vararg in a function-type annotation", function()
            -- A function-TYPE annotation still requires `...: type` (no inference).
            assert_program_syntax_error([[
                function f(g: (...) -> integer): nil
                end
            ]], "VarargColon")
        end)

        -- A BARE function type as the vararg element parses fine: `...: () -> integer`
        -- reads the element type as the function type `() -> integer` (the `...`
        -- element grammar is `simpletype`, and a bare function type is a
        -- simpletype). Pin the AST so a future grammar change is noticed.
        it("parses a bare function-type vararg element `...: () -> integer`", function()
            assert_program_ast([[
                function foo(...: () -> integer): nil
                end
            ]], {
                { _tag = "Ast.TopLevelFunc",
                    name = "foo",
                    params = {
                        { _tag = "Ast.Decl", name = false,
                          type = { _tag = "Ast.TypeFunction",
                                   argtypes = {},
                                   rettypes = { { _tag = "Ast.TypeInteger" } } } },
                    } },
            })
        end)

        -- KNOWN PRE-EXISTING LIMITATION (not varargs-specific): a PARENTHESIZED
        -- type is not a `simpletype` anywhere in the grammar, so `...: (() -> integer)`
        -- -- which tries to use a parenthesized function type as the element --
        -- fails to parse with the `TypeDecl` label. Pinned so that if the grammar
        -- ever learns parenthesized simpletypes, this test flips and we notice.
        it("rejects a PARENTHESIZED function-type vararg element (known limitation)", function()
            assert_program_syntax_error([[
                function foo(...: (() -> integer)): nil
                end
            ]], "TypeDecl")
        end)
    end)

    describe("can parse variadic function-type annotations", function()
        it("with a fixed prefix and a vararg element type", function()
            assert_type_ast("(integer, ...: string) -> integer",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeInteger" } },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeString" } })
        end)

        it("with a sole vararg element type", function()
            assert_type_ast("(...: integer) -> integer",
                { _tag = "Ast.TypeFunction",
                    argtypes = { },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeInteger" } })
        end)

        it("a non-variadic function type carries varargtype = false", function()
            assert_type_ast("(integer, string) -> integer",
                { _tag = "Ast.TypeFunction",
                    argtypes = {
                        { _tag = "Ast.TypeInteger" },
                        { _tag = "Ast.TypeString" },
                    },
                    rettypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = false,
                    flexrettype = false })
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
                "(integer, ...: string) -> (boolean, ...: value)",
                { _tag = "Ast.TypeFunction",
                    argtypes = { { _tag = "Ast.TypeInteger" } },
                    varargtype = { _tag = "Ast.TypeString" },
                    rettypes = { { _tag = "Ast.TypeBoolean" } },
                    flexrettype = { _tag = "Ast.TypeValue" } })
            assert_type_ast("() -> (...: integer)",
                { _tag = "Ast.TypeFunction", argtypes = {}, rettypes = {},
                    varargtype = false,
                    flexrettype = { _tag = "Ast.TypeInteger" } })
            assert_type_ast("() -> (...: () -> integer)",
                { _tag = "Ast.TypeFunction", rettypes = {},
                    flexrettype = { _tag = "Ast.TypeFunction",
                        argtypes = {},
                        rettypes = { { _tag = "Ast.TypeInteger" } },
                        flexrettype = false } })
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
                        { _tag = "Ast.ExpFunction", rettypes = false,
                            flexrettype = false },
                    } },
                    { _tag = "Ast.StatDecl", exps = {
                        { _tag = "Ast.ExpFunction", rettypes = {},
                            flexrettype = false },
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
            assert_type_syntax_error("() -> ...: integer", "FlexRetParens")
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
                            { _tag = "Ast.Field", name = false,
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
                            { _tag = "Ast.Field", name = false,
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
                            { _tag = "Ast.Field", name = false,
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
                            { _tag = "Ast.Field", name = false,
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

        it("parses `#...` as ExpUnop('#', ExpDots)", function()
            local stats = vararg_stats("x = #...")
            assert_is_subset({
                { _tag = "Ast.StatAssign",
                    exps = { { _tag = "Ast.ExpUnop", op = "#",
                        exp = { _tag = "Ast.ExpDots" } } } },
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

        it("rejects a 101-element lambda parameter list with ListTooLong", function()
            local src = "function f(): nil\n  local g = function(" ..
                repeated("p%d", 101, ", ") .. ") return 1 end\nend"
            assert_program_syntax_error(src, "ListTooLong")
        end)

        it("applies the limit to type parameter lists", function()
            local accepted = "record Many<" ..
                repeated("T%d", 100, ", ") .. "> end"
            assert_parses_successfuly(accepted)

            local rejected = "record TooMany<" ..
                repeated("T%d", 101, ", ") .. "> end"
            assert_program_syntax_error(rejected, "ListTooLong")
        end)

        it("applies the limit to type argument lists", function()
            local accepted_args = repeated("T%d", 100, ", ")
            local accepted = "Holder<" .. accepted_args .. ">"
            assert_type_ast(accepted, { _tag = "Ast.TypeName" })
            assert_expression_ast("make<" .. accepted_args .. ">()", {
                _tag = "Ast.ExpCall",
            })

            local rejected_args = repeated("T%d", 101, ", ")
            local rejected = "Holder<" .. rejected_args .. ">"
            assert_type_syntax_error(rejected, "ListTooLong")
            assert_expression_syntax_error(
                "make<" .. rejected_args .. ">()", "ListTooLong")
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

        it("parses a bare `raise` (exp is false)", function()
            assert_statements_ast([[ raise ]], {
                { _tag = "Ast.StatRaise", exp = false }
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
                  finallyblock = false }
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
                            finallyblock = false } }
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
                            finallyblock = false } }
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
                  catchblock = false,
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

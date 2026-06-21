local parser = require 'titan-compiler.parser'
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
    end)

    it("omitting the return annotation yields a zero-return () function", function ()
        assert_program_ast([[
            function foo()
            end
            local function bar()
            end
        ]], {
            { _tag = "Ast.TopLevelFunc", name = "foo", rettypes = {} },
            { _tag = "Ast.TopLevelFunc", name = "bar", rettypes = {} },
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
                                } },
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
                            { _tag = "Ast.ExpFunction", rettypes = {} },
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
              decl = { _tag = "Ast.Decl", name = "i", type = false },
              finish = { _tag = "Ast.ExpInteger", value = 2 },
              inc =    { _tag = "Ast.ExpInteger", value = 3 },
              start =  { _tag = "Ast.ExpInteger", value = 1 } },
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

    it("can parse function calls without the optional parenthesis", function()
        assert_expression_ast([[ f() ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = { } } })

        assert_expression_ast([[ f "qwe" ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = {
                    { _tag = "Ast.ExpString", value = "qwe" } } } })

        assert_expression_ast([[ f {} ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsFunc", args = {
                    { _tag = "Ast.ExpInitList" } } } })
    end)

    it("can parse method calls without the optional parenthesis", function()
        assert_expression_ast([[ o:m () ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsMethod", args = { } } })

        assert_expression_ast([[ o:m "asd" ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsMethod", args = {
                    { _tag = "Ast.ExpString", value = "asd" } } } })

        assert_expression_ast([[ o:m {} ]],
            { _tag = "Ast.ExpCall", args = {
                _tag = "Ast.ArgsMethod", args = {
                    { _tag = "Ast.ExpInitList" } } } })
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

    it("can parse cast expressions", function()
        assert_expression_ast([[ foo as integer ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ a.b[1].c as integer ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } })
        assert_expression_ast([[ foo as { integer } ]],
            { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeArray" } })
        assert_expression_ast([[ 2 + foo as integer ]],
            { rhs = { _tag = "Ast.ExpCast", exp = { _tag = "Ast.ExpVar" }, target = { _tag = "Ast.TypeInteger" } }})
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
    end)

    it("doesn't allow using a primitive type as a record", function()
        assert_expression_syntax_error("integer.new(10)", "ExpAssign")
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
            record
        ]], "NameRecord")

        assert_program_syntax_error([[
            record A
                x : int
        ]], "EndRecord")

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

        assert_expression_syntax_error([[ y{42 ]], "RCurlyInitList")

        assert_expression_syntax_error([[ y{42,,} ]], "ExpFieldList")

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

        it("as the last parameter of a record static (synthesized `new`)", function()
            -- Records desugar each field into a `new` static; the shared
            -- `paramlist` rule used by statics is exercised here. There is no
            -- surface syntax for a user-written vararg static, so we confirm the
            -- record's `new` parses through the same param machinery.
            assert_program_ast([[
                record Point
                    x: integer
                    y: integer
                end
            ]], {
                { _tag = "Ast.TopLevelRecord", name = "Point" },
                { _tag = "Ast.TopLevelStatic", name = "new",
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
                    varargtype = false })
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
    end)
end)

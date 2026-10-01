local cdefines = require "c-parser.cdefines"
local c99 = require "c-parser.c99"

local function register(text)
    local types = {}
    cdefines.register_define(types, "FFI_MACRO", text, {})
    return assert(types.FFI_MACRO, "macro was not registered")
end

local function candidates(...)
    local out = {}
    for _, spec in ipairs({ ... }) do
        local rank, unsigned, spelling = table.unpack(spec)
        out[#out + 1] = {
            rank = rank,
            unsigned = unsigned,
            spelling = spelling,
        }
    end
    return out
end

local function cast_type_list()
    local handler = {
        type = "typedef",
        name = "ffi_handler",
        def = {
            type = "functionptr",
            name = "ffi_handler",
            ret = { type = { "void" } },
            params = {
                { name = nil, type = { "int" } },
            },
            vararg = false,
            pointer = { "*" },
            _paramstyle = "prototype",
            _declarator_ops = { "*" },
        },
    }
    return {
        typedef_names = { ffi_handler = true },
        ffi_handler = handler,
        {
            name = "ffi_handler",
            type = handler,
        },
    }
end

local I = { "int", false, "int" }
local UI = { "int", true, "unsigned int" }
local L = { "long", false, "long" }
local UL = { "long", true, "unsigned long" }
local LL = { "long_long", false, "long long" }
local ULL = { "long_long", true, "unsigned long long" }

local function call_with_instruction_count(fn, ...)
    local arguments = table.pack(...)
    local quantum = 100
    local instructions = 0
    local previous_hook, previous_mask, previous_count = debug.gethook()
    debug.sethook(function()
        instructions = instructions + quantum
    end, "", quantum)
    local results = table.pack(pcall(
        fn, table.unpack(arguments, 1, arguments.n)))
    debug.sethook(previous_hook, previous_mask, previous_count)

    assert.is_true(results[1], results[2])
    return results[2], instructions,
        table.unpack(results, 3, results.n)
end

describe("C expression parsing", function()
    it("right-folds assignment operator chains", function()
        local exp = assert(c99.match_language_expression_grammar(
            "left = middle += right "))

        assert.equal("=", exp.op)
        assert.same({ "left" }, exp[1])
        assert.equal("+=", exp[2].op)
        assert.same({ "middle" }, exp[2][1])
        assert.same({ "right" }, exp[2][2])
    end)

    it("requires a unary expression on each assignment left-hand side",
    function()
        assert.is_nil(c99.match_language_expression_grammar(
            "left + right = value "))
        assert.is_nil(c99.match_language_expression_grammar(
            "condition ? yes : no = value "))

        -- Parentheses make the complete inner expression a primary, and thus
        -- a unary expression at the C grammar level. Whether it is an lvalue
        -- is deliberately left to the real C compiler.
        local parenthesized = assert(
            c99.match_language_expression_grammar(
                "( left + right ) = value "))
        assert.equal("=", parenthesized.op)
        assert.equal("+", parenthesized[1].op)
    end)

    it("does not recursively retry nested non-assignment expressions",
    function()
        local depth = 18
        local subject =
            string.rep("( ", depth) .. "value " ..
            string.rep(") ", depth)
        local parsed, instructions, err = call_with_instruction_count(
            c99.match_language_expression_grammar, subject)

        assert.is_truthy(parsed, err)
        -- The factored grammar takes fewer than 3,000 instructions here. The
        -- old recursive ordered choice took more than 81 million because each
        -- parenthesis doubled the complete inner parse.
        assert.is_true(instructions < 100000, tostring(instructions))
    end)

    it("borrows the typedef scope without traversing or mutating it",
    function()
        local typedef_names = setmetatable({
            ffi_handler = true,
            numeric_handler = 1,
            table_handler = {},
            untouched = false,
        }, {
            __pairs = function()
                error("typedef scope must not be copied", 0)
            end,
            __index = function()
                error("typedef scope metatable must not be consulted", 0)
            end,
        })

        local exp = assert(c99.match_typed_language_expression_grammar(
            "( ( ffi_handler ) 0 ) ", typedef_names))
        assert.same({ "ffi_handler" }, exp.cast_type)
        assert.is_true(rawget(typedef_names, "ffi_handler"))
        assert.is_false(rawget(typedef_names, "untouched"))
        assert.is_nil(rawget(typedef_names, "new_name"))
        local numeric = assert(c99.match_typed_language_expression_grammar(
            "( ( numeric_handler ) 0 ) ", typedef_names))
        local tabular = assert(c99.match_typed_language_expression_grammar(
            "( ( table_handler ) 0 ) ", typedef_names))
        assert.same({ "numeric_handler" }, numeric.cast_type)
        assert.same({ "table_handler" }, tabular.cast_type)
        assert.is_truthy(c99.match_typed_language_expression_grammar(
            "ordinary_identifier ", typedef_names))

        -- The borrowed scope is restored even after a failed complete match.
        assert.is_nil(c99.match_typed_language_expression_grammar(
            "( ( ffi_handler ) 0 ) trailing ", typedef_names))
        assert.is_nil(c99.match_typed_language_expression_grammar(
            "( ( ffi_handler ) 0 ) ", {}))
    end)
end)

describe("C declaration parsing", function()
    it("parses nested callback parameter lists once", function()
        local depth = 16
        local parameter = "int value "
        for index = depth, 1, -1 do
            parameter =
                "void ( * callback" .. index .. " ) ( " ..
                parameter .. ") "
        end
        local subject =
            "extern void root ( " .. parameter .. ") ; $EOF$"
        local parsed, instructions, err = call_with_instruction_count(
            c99.match_language_grammar, subject)

        assert.is_truthy(parsed, err)
        assert.equal(1, #parsed)
        -- Retrying the complete ordinary parameter list as a possible vararg
        -- list doubled at each nested callback and took over 4.9 million
        -- instructions at this depth. One optional vararg tail stays linear.
        assert.is_true(instructions < 100000, tostring(instructions))
    end)

    for _, kind in ipairs({ "union", "struct" }) do
        it("parses nested named inline-" .. kind .. " members once", function()
            local depth = 16
            local field = "int leaf ; "
            for index = depth, 1, -1 do
                field =
                    kind .. " { " .. field .. "} field" .. index .. " ; "
            end
            local parsed, instructions, err = call_with_instruction_count(
                c99.match_language_grammar,
                "struct Root { " .. field .. "} ; $EOF$")

            assert.is_truthy(parsed, err)
            assert.equal(1, #parsed)
            local outer = parsed[1].spec[1].fields[1]
            assert.equal("field1", outer.ids[1].name)
            assert.equal(kind, outer.type[1].type)
            -- Trying the complete body first as an anonymous union and then again
            -- as a named field took over three million instructions at this depth.
            assert.is_true(instructions < 100000, tostring(instructions))
        end)

        it("preserves trailing inline-" .. kind .. " specifier qualifiers", function()
            local parsed, err = c99.match_language_grammar(
                "struct Root { " .. kind .. " { int leaf ; } const value ; } ; $EOF$")

            assert.is_truthy(parsed, err)
            assert.equal(1, #parsed)
            local field = parsed[1].spec[1].fields[1]
            assert.equal("value", field.ids[1].name)
            assert.equal(kind, field.type[1].type)
            assert.equal("const", field.type[2])
        end)

        it("rejects an inline-" .. kind .. " specifier tail without a declarator", function()
            local parsed, err = c99.match_language_grammar(
                "struct Root { " .. kind .. " { int leaf ; } const ; } ; $EOF$")

            assert.is_truthy(parsed, err)
            assert.equal(0, #parsed)
        end)
    end

end)

describe("C declaration recovery", function()
    it("advances over a failed leading specifier run once", function()
        local count = 640
        local parsed, instructions, err = call_with_instruction_count(
            c99.match_language_grammar,
            string.rep("int ", count) .. "$EOF$")

        assert.is_truthy(parsed, err)
        assert.equal(0, #parsed)
        assert.equal(1, c99.recoveries)
        -- The failed prefix is explored once and then skipped. Retrying every
        -- remaining suffix took over 2.5 million instructions at this size;
        -- the progress-aware recovery takes fewer than 20,000.
        assert.is_true(instructions < 100000, tostring(instructions))
    end)

    it("still resynchronizes after unsupported prefix tokens", function()
        local parsed, err = c99.match_language_grammar(
            "extern garbage extern int recovered ; $EOF$")

        assert.is_truthy(parsed, err)
        assert.equal(1, #parsed)
        assert.equal("recovered", parsed[1].ids[1].decl.name)
        assert.equal(2, c99.recoveries)
    end)
end)

describe("C object-like macro metadata", function()
    it("registers a final macro map in deterministic byte order", function()
        local definitions = {
            zeta = { "4" },
            alpha = { "3" },
            _upper = { "2" },
            Alpha = { "1" },
        }
        setmetatable(definitions, {
            __pairs = function(map)
                local order = { "zeta", "alpha", "_upper", "Alpha" }
                local index = 0
                return function()
                    index = index + 1
                    local name = order[index]
                    if name then return name, rawget(map, name) end
                end
            end,
        })

        local types = {}
        cdefines.register_defines(types, definitions)
        assert.same({ "Alpha", "_upper", "alpha", "zeta" }, {
            types[1].name,
            types[2].name,
            types[3].name,
            types[4].name,
        })
    end)

    it("publishes outer casts with their declared C target type", function()
        local types = cast_type_list()

        cdefines.register_define(
            types, "FFI_TYPEDEF_NULL",
            "( ( ffi_handler ) ( 0 ) )", {})
        local typedef_null = assert(types.FFI_TYPEDEF_NULL)
        assert.same({ "ffi_handler" }, typedef_null.type)
        assert.same({ "ffi_handler" }, typedef_null._declarator_base)
        assert.same({}, typedef_null._declarator_ops)
        assert.same({ "0" }, typedef_null._macro_cast.operand)
        assert.is_nil(typedef_null.macro_expression)

        cdefines.register_define(
            types, "FFI_DIRECT_NULL",
            "( ( void ( * ) ( int ) ) 0 )", {})
        local direct_null = assert(types.FFI_DIRECT_NULL)
        assert.equal("functionptr", direct_null.type)
        assert.same({ "*" }, direct_null._declarator_ops)
        assert.same({ "void" }, direct_null.ret.type)
        assert.same({ "int" }, direct_null.params[1].type)

        cdefines.register_define(
            types, "FFI_CAST_LONG",
            "( ( unsigned long ) 7 )", {})
        assert.same(
            { "unsigned", "long" },
            types.FFI_CAST_LONG.type)
    end)

    it("does not infer a type from non-outer or malformed casts", function()
        for _, replacement in ipairs({
            "( ( ffi_handler ) 0 ) + 1",
            "( ( int * ) 0 ) [ 0 ]",
            "( ( int * ) 0 ) -> value",
            "( ( void ( * ) ( int ) ) 0 ) ( 1 )",
            "( ( missing_handler ) 0 )",
            "( ( ffi_handler ) 0 ) trailing",
        }) do
            local types = cast_type_list()
            cdefines.register_define(
                types, "FFI_REJECTED", replacement, {})
            assert.is_nil(types.FFI_REJECTED, replacement)
        end
    end)

    it("types a dereferenced accessor macro but rejects unknown postfixes",
    function()
        local accessor = {
            type = "function",
            name = "ffi_int_location",
            ret = { type = { "int", "*" } },
            params = {},
            vararg = false,
        }
        local types = {
            ffi_int_location = accessor,
            {
                name = "ffi_int_location",
                type = accessor,
            },
        }

        cdefines.register_define(
            types, "FFI_DEREFERENCED",
            "* ffi_int_location ( )", {})
        assert.same({ "int" }, types.FFI_DEREFERENCED.type)

        for _, replacement in ipairs({
            "ffi_unknown ( 0 )",
            "ffi_unknown [ 0 ]",
            "ffi_unknown -> field",
            "ffi_unknown ++",
        }) do
            cdefines.register_define(
                types, "FFI_REJECTED", replacement, {})
            assert.is_nil(types.FFI_REJECTED, replacement)
        end
    end)

    it("records pure dotted field projections without publishing values",
    function()
        local types = {}

        cdefines.register_define(
            types, "ffi_public", "ffi_storage . nested . value", {})

        assert.is_nil(types.ffi_public)
        assert.equal(0, #types)
        local projection = assert(types.field_macro_paths.ffi_public)
        assert.equal("ffi_public", projection.name)
        assert.same(
            { "ffi_storage", "nested", "value" },
            projection.path)
        assert.equal(
            "ffi_storage . nested . value",
            projection.replacement)
    end)

    it("rejects non-dotted field macro replacement shapes", function()
        for _, replacement in ipairs({
            "ffi_storage",
            "ffi_storage -> value",
            "ffi_storage . value ( )",
            "ffi_storage . value [ 0 ]",
            "ffi_storage + value",
        }) do
            local types = {}
            cdefines.register_define(
                types, "ffi_public", replacement, {})
            assert.is_nil(types.field_macro_paths,
                "unexpected field projection for " .. replacement)
        end
    end)

    it("classifies fields against the final transitive macro environment",
    function()
        local definitions = {
            projected = { "alias", ".", "leaf" },
            alias = { "nested" },
        }

        local projection =
            assert(cdefines.classify_field_macro(
                "projected", definitions))
        assert.same({ "nested", "leaf" }, projection.path)

        definitions.alias = { "other" }
        projection = assert(cdefines.classify_field_macro(
            "projected", definitions))
        assert.same({ "other", "leaf" }, projection.path)

        definitions.projected = { "42" }
        local unsupported = assert(cdefines.classify_field_macro(
            "projected", definitions))
        assert.is_true(unsupported.unsupported)
        assert.equal("42", unsupported.replacement)

        definitions.projected = nil
        assert.is_nil(cdefines.classify_field_macro(
            "projected", definitions))
        definitions.projected = {
            args = { "value" },
            repl = { "value" },
        }
        assert.is_nil(cdefines.classify_field_macro(
            "projected", definitions))
    end)

    it("publishes a bare identifier alias to a parsed C function", function()
        local types = {}
        local target = {
            type = "function",
            name = "ffi_replacement",
            ret = { type = { "void", "*" } },
            params = {
                { name = "count", type = { "size_t" } },
            },
            paramnames = { "count" },
            paramnames_state = "complete",
            vararg = false,
        }
        types.ffi_replacement = target
        table.insert(types, {
            name = "ffi_replacement",
            type = target,
        })

        cdefines.register_define(
            types, "ffi_public", "ffi_replacement", {})

        local alias = assert(types.ffi_public)
        assert.equal("function", alias.type)
        assert.equal("ffi_public", alias.name)
        assert.equal(target.ret, alias.ret)
        assert.equal(target.params, alias.params)
        assert.equal(target.paramnames, alias.paramnames)
        assert.equal(target.paramnames_state, alias.paramnames_state)
        assert.equal(target.vararg, alias.vararg)
        assert.not_equal(target, alias)
        assert.equal(alias, types[2].type)
        assert.equal("ffi_public", types[2].name)

        cdefines.register_define(
            types, "ffi_unresolved", "ffi_declared_elsewhere", {})
        assert.is_nil(types.ffi_unresolved)
        assert.equal(2, #types)
    end)

    it("replaces shadowed typedefs but suppresses macro-only type aliases",
    function()
        local target = {
            type = "typedef",
            name = "ffi_replacement_type",
            def = { "double" },
        }
        local existing = {
            type = "typedef",
            name = "ffi_public_type",
            def = { "int" },
        }
        local types = {
            ffi_replacement_type = target,
            ffi_public_type = existing,
            {
                name = "ffi_replacement_type",
                type = target,
            },
            {
                name = "ffi_public_type",
                type = existing,
            },
        }

        cdefines.register_define(
            types, "ffi_public_type", "ffi_replacement_type", {})
        cdefines.register_define(
            types, "ffi_macro_only_type", "ffi_replacement_type", {})

        local alias = assert(types.ffi_public_type)
        assert.not_equal(existing, alias)
        assert.not_equal(target, alias)
        assert.equal("typedef", alias.type)
        assert.equal("ffi_public_type", alias.name)
        assert.equal(target.def, alias.def)
        assert.equal(alias, types[3].type)
        assert.equal("ffi_public_type", types[3].name)
        assert.is_nil(types.ffi_macro_only_type)
        assert.equal(3, #types)

        cdefines.register_define(
            types, "ffi_replacement_type", "ffi_replacement_type", {})
        assert.equal(target, types.ffi_replacement_type)
        assert.equal(3, #types)

        local enum_value = {
            type = "enum",
            value = 7,
        }
        types.ffi_enum_value = enum_value
        table.insert(types, {
            name = "ffi_enum_value",
            type = enum_value,
        })
        cdefines.register_define(
            types, "ffi_enum_alias", "ffi_enum_value", {})
        assert.same({ "int" }, types.ffi_enum_alias.type)
        assert.equal(5, #types)
    end)

    it("preserves the C99 candidate classes for every integer suffix and base",
    function()
        local bases = {
            {
                name = "decimal",
                radix = 10,
                digits = "17",
                token = "17",
                unsuffixed = candidates(I, L, LL),
                long = candidates(L, LL),
                long_long = candidates(LL),
            },
            {
                name = "octal",
                radix = 8,
                digits = "17",
                token = "017",
                unsuffixed = candidates(I, UI, L, UL, LL, ULL),
                long = candidates(L, UL, LL, ULL),
                long_long = candidates(LL, ULL),
            },
            {
                name = "hexadecimal",
                radix = 16,
                digits = "11",
                token = "0x11",
                unsuffixed = candidates(I, UI, L, UL, LL, ULL),
                long = candidates(L, UL, LL, ULL),
                long_long = candidates(LL, ULL),
            },
        }
        local suffixes = {
            {
                spelling = "",
                normalized = "",
                unsigned = false,
                rank = "none",
                expected = "unsuffixed",
                best_effort_type = { "int" },
            },
            {
                spelling = "U",
                normalized = "u",
                unsigned = true,
                rank = "none",
                candidates = candidates(UI, UL, ULL),
                best_effort_type = { "int" },
            },
            {
                spelling = "L",
                normalized = "l",
                unsigned = false,
                rank = "long",
                expected = "long",
                best_effort_type = { "long" },
            },
            {
                spelling = "UL",
                normalized = "ul",
                unsigned = true,
                rank = "long",
                candidates = candidates(UL, ULL),
                best_effort_type = { "long" },
            },
            {
                spelling = "LL",
                normalized = "ll",
                unsigned = false,
                rank = "long_long",
                expected = "long_long",
                best_effort_type = { "long", "long" },
            },
            {
                spelling = "ULL",
                normalized = "ull",
                unsigned = true,
                rank = "long_long",
                candidates = candidates(ULL),
                best_effort_type = { "long", "long" },
            },
        }

        for _, base in ipairs(bases) do
            for _, suffix in ipairs(suffixes) do
                local ctype = register(base.token .. suffix.spelling)
                local literal = assert(ctype.integer_literals[1])
                assert.equal(base.token .. suffix.spelling, literal.token)
                assert.equal(base.name, literal.base)
                assert.equal(base.radix, literal.radix)
                assert.equal(base.digits, literal.digits)
                assert.equal(suffix.spelling, literal.suffix)
                assert.equal(suffix.normalized, literal.normalized_suffix)
                assert.equal(suffix.unsigned, literal.unsigned)
                assert.equal(suffix.rank, literal.rank_suffix)
                assert.same(
                    suffix.candidates or base[suffix.expected],
                    literal.candidate_classes)
                assert.same(suffix.best_effort_type, ctype.type)
                assert.equal(
                    literal,
                    ctype.macro_expression.integer_literal)
            end
        end
    end)

    it("retains and annotates every literal in a compound expression", function()
        local ctype = register("( 1U + 02L ) << 0x3ULL")
        local exp = ctype.macro_expression

        assert.equal("<<", exp.op)
        assert.equal("+", exp[1].op)
        assert.same({ "1U", "02L", "0x3ULL" }, {
            ctype.integer_literals[1].token,
            ctype.integer_literals[2].token,
            ctype.integer_literals[3].token,
        })
        assert.equal(ctype.integer_literals[1],
            exp[1][1].integer_literal)
        assert.equal(ctype.integer_literals[2],
            exp[1][2].integer_literal)
        assert.equal(ctype.integer_literals[3],
            exp[2].integer_literal)

        -- Metadata does not finalize a target-dependent result. Existing
        -- best-effort publication still infers this expression as `long`.
        assert.same({ "long" }, ctype.type)
    end)

    it("retains logical and unary integer expressions for profile evaluation",
       function()
        local logical = register("0 && ( 1 / 0 )")
        assert.equal("&&", logical.macro_expression.op)
        assert.same({ "int" }, logical.type)

        local complement = register("~ 0U")
        assert.equal("~", complement.macro_expression.op)
        assert.same({ "int" }, complement.type)

        local negated = register("! 0")
        assert.equal("!", negated.macro_expression.op)
        assert.same({ "int" }, negated.type)
    end)
end)

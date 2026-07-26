local cdefines = require "c-parser.cdefines"

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

describe("C object-like macro metadata", function()
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

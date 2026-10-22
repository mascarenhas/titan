local typedecl = require 'titan-compiler.typedecl'
local maybe3 = require 'titan-compiler.maybe3'

local ast = typedecl("Ast", {
    Type = {
        TypeNil         = {"loc"},
        TypeBoolean     = {"loc"},
        TypeInteger     = {"loc"},
        TypeFloat       = {"loc"},
        TypeString      = {"loc"},
        TypeValue       = {"loc"},
        TypeQualName    = {"loc", "module", "name", "typeargs"},
        TypeName        = {"loc", "name", "typeargs"},
        TypeForeignName = {"loc", "name"},
        TypeCPointer    = {"loc", "subtype", "const"},
        TypeCArray      = {"loc", "base", "length"},
        TypeOwned       = {"loc", "subtype"}, -- complete raw foreign operand; checker resolves pointer/array aliases
        TypeArray       = {"loc", "subtype", "isconst"},
        TypeMap         = {"loc", "keystype", "valuestype"},
        TypeFunction    = {"loc", "argtypes", "rettypes", "varargtype", "flexrettype"},
        TypeForeignFunction = {"loc", "argtypes", "rettypes", "varargtype", "flexrettype"},
        TypeOption      = {"loc", "basetype"}
    },

    TopLevel = {
        TopLevelMethod  = {"loc", "class", "name", "params", "rettypes", "flexrettype", "block", "typeparams"},
        TopLevelStatic  = {"loc", "class", "name", "params", "rettypes", "flexrettype", "block", "typeparams"},
        TopLevelFunc    = {"loc", "islocal", "name", "params", "rettypes", "flexrettype", "block", "typeparams"},
        TopLevelForeignFunc = {"loc", "name", "params", "rettypes", "flexrettype", "block"},
        TopLevelVar     = {"loc", "islocal", "isconst", "decl", "value"},
        TopLevelTypeAlias = {"loc", "islocal", "name", "type"},
        TopLevelForeignTypeAlias = {"loc", "name", "type"},
        TopLevelRecord  = {"loc", "name", "fields", "typeparams"},
        TopLevelUnion   = {"loc", "name", "variants", "typeparams"},
        TopLevelInterface = {"loc", "name", "members", "fields", "methods", "typeparams"},
        TopLevelImport  = {"loc", "localname", "modname", "source_required"},
        TopLevelForeignImport = {"loc", "headername"},
    },

    TypeParam = {
        TypeParam = {"loc", "name", "constraint"},
    },

    Decl = {
        Decl = {"loc", "name", "type", "option", "isconst"},
    },

    Union = {
        UnionVariant = {"loc", "name", "parts"},
    },

    Interface = {
        InterfaceMethod = {"loc", "name", "params", "rettypes", "flexrettype", "typeparams"},
    },

    Stat = {
        StatBlock       = {"loc", "stats"},
        StatWhile       = {"loc", "condition", "block"},
        StatRepeat      = {"loc", "block", "condition"},
        StatIf          = {"loc", "thens", "elsestat"},
        StatFor         = {"loc", "decl", "start", "finish", "inc", "block"},
        StatForIn       = {"loc", "decls", "exps", "block"},
        StatAssign      = {"loc", "vars", "exps"}, -- parser candidates are Exp nodes until checker lvalue validation
        StatDecl        = {"loc", "decls", "exps"},
        StatCall        = {"loc", "callexp"},
        StatReturn      = {"loc", "exps"},
        StatCase        = {"loc", "exp", "arms", "elseblock"},
        StatBreak       = {"loc"},
        StatRaise       = {"loc", "exp"},   -- `raise <exp>`; nil `exp` means bare re-raise
        StatTry         = {"loc", "block", "catchblock", "finallyblock"},
    },

    Then = {
        Then            = {"loc", "condition", "block"},
    },

    Case = {
        CaseArm         = {"loc", "name", "bindings", "block", "named"},
    },

    Var = {
        VarName         = {"loc", "name"},
        VarBracket      = {"loc", "exp1", "exp2"},
        VarDot          = {"loc", "exp", "name"}
    },

    Exp = {
        ExpNil          = {"loc"},
        ExpForeignType  = {"loc", "type"},
        ExpBool         = {"loc", "value"},
        ExpInteger      = {"loc", "value"},
        ExpFloat        = {"loc", "value"},
        ExpString       = {"loc", "value"},
        ExpInitList     = {"loc", "fields"},
        ExpCall         = {"loc", "exp", "args", "typeargs"},
        ExpVar          = {"loc", "var"},
        ExpUnop         = {"loc", "op", "exp"},
        ExpConcat       = {"loc", "exps"},
        ExpBinop        = {"loc", "lhs", "op", "rhs"},
        ExpCast         = {"loc", "exp", "target"},
        ExpIs           = {"loc", "exp", "target"},
        ExpAdjust       = {"loc", "exp"},                   -- adjust calls, varargs, spreads, or ranges to one value
        ExpExtra        = {"loc", "exp", "index", "_type"}, -- index-th (>1) value of call
        ExpFunction     = {"loc", "params", "rettypes", "flexrettype", "block"}, -- anonymous function expression
        ExpMethodRef    = {"loc", "exp", "name"}, -- bound method reference `obj:m` (no call)
        ExpUnionInit    = {"loc", "owner", "variant", "values"}, -- synthesized union constructor body
        ExpDots         = {"loc"},          -- bare `...`
        ExpDotsIndex    = {"loc", "exp"},   -- `...[e]` (checker sets _nilfill, _type)
        ExpDotsLen      = {"loc"},          -- explicit `#...`
        ExpSubset       = {"loc", "exp", "first", "last"}, -- `exp[first,last]`; nil means omitted
        ExpSpread       = {"loc", "exp", "first", "last"}, -- bounds populated by checker
        ExpSpreadIndex  = {"loc", "spread", "index", "_type"} -- checker-synthesized projection
    },

    Args = {
        ArgsFunc        = {"loc", "args"},
        ArgsMethod      = {"loc", "method", "args"},
        ArgsNamedFunc   = {"loc", "fields"},
        ArgsNamedMethod = {"loc", "method", "fields"},
    },

    Field = {
        Field           = {"loc", "name", "exp"},
    },
})

-- Implementation notes: doc/implementation/ast-typedecl.md#decorations-who-writes-what-who-reads-it
-- These annotations distinguish an unfinished analysis from a completed
-- analysis that found no sound plan. Ordinary optional syntax stays nil.
local function analysis_fields(constructor, fields)
    local build = ast[constructor]
    ast[constructor] = function(...)
        local node = build(...)
        for _, field in ipairs(fields) do node[field] = maybe3.unknown() end
        return node
    end
end

for _, constructor in ipairs {
    "TopLevelFunc", "TopLevelMethod", "TopLevelStatic",
    "TopLevelForeignFunc", "ExpFunction", "InterfaceMethod",
} do
    analysis_fields(constructor, {
        "_lua_vararg_dynamic_plan", "_strict_vararg_guard_plan",
        "_bound_strict_vararg_guard_plan",
    })
end
analysis_fields("TopLevelVar", { "_lua_write_dynamic_plan" })
analysis_fields("Decl", { "_dynamic_plan" })
analysis_fields("VarBracket", { "_read_guard" })
analysis_fields("ExpInitList", { "_array_writer_plan" })
analysis_fields("ExpSpread", { "_spread_optional_guard", "_spread_open_guard" })
analysis_fields("ExpCall", {
    "_lua_open_result_dynamic_plan", "_strict_open_result_guard_plan",
})
analysis_fields("ExpCast", { "_written_cast" })
analysis_fields("ExpIs", { "_written_cast" })
analysis_fields("ExpBinop", { "_comparison" })

return ast

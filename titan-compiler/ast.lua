local typedecl = require 'titan-compiler.typedecl'

return typedecl("Ast", {
    Type = {
        TypeNil         = {"loc"},
        TypeBoolean     = {"loc"},
        TypeInteger     = {"loc"},
        TypeFloat       = {"loc"},
        TypeString      = {"loc"},
        TypeValue       = {"loc"},
        TypeQualName    = {"loc", "module", "name"},
        TypeName        = {"loc", "name"},
        TypeCPointer    = {"loc", "subtype", "const"},
        TypeCArray      = {"loc", "base", "length"},
        TypeCOwned      = {"loc", "subtype", "count"},
        TypeArray       = {"loc", "subtype"},
        TypeMap         = {"loc", "keystype", "valuestype"},
        TypeFunction    = {"loc", "argtypes", "rettypes", "varargtype", "flexrettype"},
        TypeOption      = {"loc", "basetype"}
    },

    TopLevel = {
        TopLevelMethod  = {"loc", "class", "name", "params", "rettypes", "flexrettype", "block"},
        TopLevelStatic  = {"loc", "class", "name", "params", "rettypes", "flexrettype", "block"},
        TopLevelFunc    = {"loc", "islocal", "name", "params", "rettypes", "flexrettype", "block"},
        TopLevelVar     = {"loc", "islocal", "decl", "value"},
        TopLevelTypeAlias = {"loc", "islocal", "name", "type"},
        TopLevelRecord  = {"loc", "name", "fields"},
        TopLevelUnion   = {"loc", "name", "variants"},
        TopLevelImport  = {"loc", "localname", "modname"},
        TopLevelForeignImport = {"loc", "localname", "headername"},
    },

    Decl = {
        Decl = {"loc", "name", "type", "option"},
    },

    Union = {
        UnionVariant = {"loc", "name", "payload"},
    },

    Stat = {
        StatBlock       = {"loc", "stats"},
        StatWhile       = {"loc", "condition", "block"},
        StatRepeat      = {"loc", "block", "condition"},
        StatIf          = {"loc", "thens", "elsestat"},
        StatFor         = {"loc", "decl", "start", "finish", "inc", "block"},
        StatForIn       = {"loc", "decls", "exps", "block"},
        StatAssign      = {"loc", "vars", "exps"},
        StatDecl        = {"loc", "decls", "exps"},
        StatCall        = {"loc", "callexp"},
        StatReturn      = {"loc", "exps"},
        StatCase        = {"loc", "exp", "arms", "elseblock"},
        StatBreak       = {"loc"},
        StatRaise       = {"loc", "exp"},   -- `raise <exp>`; `exp` false ⇒ bare re-raise
        StatTry         = {"loc", "block", "catchblock", "finallyblock"},
    },

    Then = {
        Then            = {"loc", "condition", "block"},
    },

    Case = {
        CaseArm         = {"loc", "name", "binding", "block"},
    },

    Var = {
        VarName         = {"loc", "name"},
        VarBracket      = {"loc", "exp1", "exp2"},
        VarDot          = {"loc", "exp", "name"}
    },

    Exp = {
        ExpNil          = {"loc"},
        ExpBool         = {"loc", "value"},
        ExpInteger      = {"loc", "value"},
        ExpFloat        = {"loc", "value"},
        ExpString       = {"loc", "value"},
        ExpInitList     = {"loc", "fields"},
        ExpCall         = {"loc", "exp", "args"},
        ExpVar          = {"loc", "var"},
        ExpUnop         = {"loc", "op", "exp"},
        ExpConcat       = {"loc", "exps"},
        ExpBinop        = {"loc", "lhs", "op", "rhs"},
        ExpCast         = {"loc", "exp", "target"},
        ExpIs           = {"loc", "exp", "target"},
        ExpAdjust       = {"loc", "exp"},                   -- adjust call to just first value
        ExpExtra        = {"loc", "exp", "index", "_type"}, -- index-th (>1) value of call
        ExpFunction     = {"loc", "params", "rettypes", "flexrettype", "block"}, -- anonymous function expression
        ExpMethodRef    = {"loc", "exp", "name"}, -- bound method reference `obj:m` (no call)
        ExpUnionInit    = {"loc", "owner", "variant", "value"}, -- synthesized union constructor body
        ExpDots         = {"loc"},          -- bare `...`
        ExpDotsIndex    = {"loc", "exp"},   -- `...[e]` (checker sets _nilfill, _type)
        ExpDotsLen      = {"loc"}           -- `#...` (checker-normalized, §3.5)
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

local syntax_errors = {}

-- Implementation notes: doc/implementation/lexer-parser.md#the-error-label-system
local errors = {
    -- The `fail` label is the default "parsing failed" error number
    fail = "Syntax Error",

    TopLevelDecl = "Expected a complete top-level declaration.",
    Statement = "Expected a complete statement.",
    ExpSuffix = "Expected a member, call, or bracket suffix.",
    ExpReturn = "Expected an expression in the return list.",

    --
    -- Lexer errors
    -- (tested in spec/lexer_spec.lua)
    --

    MalformedNumber = "Malformed number.",

    UnclosedLongString = "Unclosed long string or long comment.",

    UnclosedShortString = "Unclosed short string.",

    InvalidEscape = "Invalid escape character in string." ,

    MalformedEscape_decimal = "Decimal escape too large",

    MalformedEscape_u = "\\u escape sequence is malformed.",

    MalformedEscape_x = "\\x escape sequences must have exactly two hexadecimal digits.",

    --
    -- Parser errors
    -- (tested in spec/parser_spec.lua)
    --

   NameFunc = "Expected a function name after 'function'.",

   NameStatic = "Expected a record function name after the dot.",

   LParPList = "Expected '(' for the parameter list.",

   RParPList = "Expected ')' to close the parameter list.",

   TypeFunc = "Expected a type in function declaration.",

   NameTypeParam = "Expected a type parameter name after '<|' or ','.",

   TypeParamConstraint = "Expected an Interface application after ':' in type parameter constraint.",

   RAngleTypeParams = "Expected '|>' to close the type parameter list.",

   TypeArgument = "Expected a type argument after '<|' or ','.",

   RAngleTypeArgs = "Expected '|>' to close the type argument list.",

   GenericForeignFunc = "Foreign functions cannot declare type parameters.",

   GenericLambda = "Anonymous functions cannot declare type parameters.",

   GenericTypeAlias = "Type aliases cannot declare type parameters.",

   EndFunc = "Expected 'end' to close the function body.",

   ParamSemicolon = "Expected ':' after parameter name.",

   VarargColon = "Expected ':' after '...' in a variadic parameter declaration.",

   FlexRetColon = "Expected ':' after '...' in a flexible return declaration.",

   FlexRetType = "Expected a type after ':' in a flexible return declaration.",

   FlexRetLast = "A flexible return must be the last return type.",

   FlexRetParens = "A flexible return must appear inside a parenthesized return list.",

   AssignVar = "Expected '=' after variable declaration.",

   ExpVarDec = "Expected an expression to initialize variable.",

   NameTypeAlias = "Expected a name after 'type'.",

   AssignTypeAlias = "Expected '=' after type alias name.",

   TypeTypeAlias = "Expected a type after '=' in type alias declaration.",

   NameRecord = "Expected a record name after 'record'.",

   EndRecord = "Expected 'end' to close the record.",

   FieldRecord = "Expected a field in record declaration.",

   NameUnion = "Expected a union name after 'union'.",

   VariantUnion = "Expected at least one variant in union declaration.",

   NameUnionVariant = "Expected a variant name after 'local'.",

   TypeUnionVariant = "Expected a union variant payload type.",

   NameVariantPayload = "Expected a union variant payload name after ','.",

   ColonVariantPayload = "Expected ':' after the union variant payload name.",

   LParenVariant = "Expected '(' after the variant name.",

   RParenVariant = "Expected ')' after the variant payload or binding.",

   RParenVariantPayload = "Expected ')' after the single unnamed variant payload type.",

   LParenCaseVariant = "Expected '(' or '{' after the case variant name.",

   RCurlyCaseVariant = "Expected '}' after the named case bindings.",

   NameCaseBinding = "Expected a local variable name in the case binding list.",

   NameCasePart = "Expected a variant payload name after '=' in a named case binding.",

   DuplicateCasePart = "A named case binding cannot reference the same payload part twice.",

   ForeignReturnColon = "Expected ':' before the foreign function result type.",

   ForeignTypeMember = "Expected an allocation or layout operation after the foreign type.",

   AssignField = "Expected '=' after the constructor field key.",

   EndUnion = "Expected 'end' to close the union.",

   LocalInterface = "Interfaces cannot be local.",

   NestedInterface = "Interface declarations are only allowed at module top level.",

   NameInterface = "Expected an interface name after 'interface'.",

   MethodInterface = "Expected at least one method in interface declaration.",

   InterfaceMember = "Expected at least one field or method in interface declaration.",

   LocalInterfaceMethod = "Interface methods cannot be local.",

   LocalInterfaceField = "Interface fields cannot be local.",

   NameInterfaceMethod = "Expected an interface method name after 'function'.",

   LParInterfaceMethod = "Expected '(' for the interface method parameter list.",

   RParInterfaceMethod = "Expected ')' to close the interface method parameter list.",

   TypeInterfaceMethod = "Expected a type in interface method declaration.",

   ColonInterfaceField = "Expected ':' after the name of an interface field.",

   TypeInterfaceField = "Expected a type name after ':' in interface field declaration.",

   MemberInterface = "Expected a bodyless interface field or method declaration or 'end'.",

   EndInterface = "Expected 'end' to close the interface.",

   NameImport = "Expected a name after 'local'.",

    --this label is not thrown in rule 'import' because rule 'toplevelvar'
    --matches an invalid input like "local bola import"
    AssignImport = "Expected '='.",

    --this label is not thrown in rule 'import' because rule 'toplevelvar'
    --matches an input like "local bola = X", given that X is a valid expression,
    --or throws a label when X is not a valid expression
    ReservedFFI = "The name 'ffi' is reserved for the module C namespace.",
    BoundForeignImport = "Foreign imports are unbound; use 'foreign import' and access C names through 'ffi'.",
    ImportImport = "Expected 'import' keyword.",

    StringLParImport = "Expected the name of a module after '('.",

    RParImport = "Expected ')' to close import declaration.",

    StringImport = "Expected the name of a module after 'import'.",

    DeclParList = "Expected a variable name after ','.",

    TypeDecl = "Expected a type name after ':'.",

    CArrayExtent = "Expected an integer literal extent in an automatic C array declaration.",

    RBracketCArray = "Expected ']' after the extent in an automatic C array declaration.",

    CArrayOnlyAutomatic = "Source-written fixed C array syntax requires a qualified type on a single initializer-less automatic local.",

    COwnedShape = "Expected '*' for one owned C object or '[]' for a counted owned C array after 'owned'.",

    OwnedPayload = "Expected a foreign type after 'owned'.",

    RBracketCOwned = "Expected ']' to close a counted owned C array type.",

   TypeType = "Expected a type name after '{'.",

   TypeConstArray = "Expected an element type after '{' in const Array type.",

   ConstMap = "The const type qualifier applies to Arrays, not Maps.",

   RCurlyType = "Expected '}' to close type specification.",

    LParenType = "Expected type after '('",

    TypelistType = "Expected type after ','",

    RParenTypelist = "Expected ')' to close type list",

    TypeFunctionNoRet = "Expected '->' after a parameter type list; parentheses can group only one type.",

    OptionTypeList = "The '?' suffix requires one type, not an empty, multiple, or flexible result list.",

    ForeignFunctionNoRet = "Expected '->' after foreign function parameter types",

    ForeignFunctionNoTypes = "Expected parameter types for foreign function",

    TypeReturnTypes = "Expected return types after `->` to finish the function type",

    ColonRecordField = "Expected ':' after the name of a record field.",

    TypeRecordField = "Expected a type name after ':'.",

    EndBlock = "Expected 'end' to close block.",

    CatchBlock = "Expected a block after 'catch'.",

    ExpRaiseTrace = "Expected a trace expression after ',' in 'raise'.",

    DeferStatement = "Expected a statement after 'defer'.",

    DeferDefer = "Expected a non-defer statement after 'defer'.",

    ExpWhile = "Expected an expression after 'while'.",

    DoWhile = "Expected 'do' in while statement.",

    EndWhile = "Expected 'end' to close the while statement.",

    UntilRepeat = "Expected 'until' in repeat statement.",

    ExpRepeat = "Expected an expression after 'until'.",

    ExpIf = "Expected an expression after 'if'.",

    ThenIf = "Expected 'then' in if statement.",

    EndIf = "Expected 'end' to close the if statement.",

    ExpCase = "Expected an expression after 'case'.",

    WhenCase = "Expected at least one 'when' arm in case statement.",

    NameCaseVariant = "Expected a variant name after 'when'.",

    NameCaseBinding = "Expected a binding name after ':'.",

    ThenCase = "Expected 'then' in case arm.",

    EndCase = "Expected 'end' to close the case statement.",

    DeclFor = "Expected variable declaration in for statement.",

    AssignFor = "Expected '=' after variable declaration in for statement.",

    Exp1For = "Expected an expression after '='.",

    CommaFor = "Expected ',' in for statement.",

    Exp2For = "Expected an expression after ','.",

    Exp3For = "Expected an expression after ','.",

    DoFor = "Expected 'do' in for statement.",

    EndFor = "Expected 'end' to close the for statement.",

    InFor = "Expected 'in' in generic for statement.",

    ExpForIn = "Expected an expression after 'in'.",

    DoForIn = "Expected 'do' in generic for statement.",

    EndForIn = "Expected 'end' to close the generic for statement.",

    DeclLocal = "Expected variable declaration after 'local'.",

    AssignLocal = "Expected '=' after variable declaration.",

    ExpLocal = "Expected an expression after '='.",

    AssignAssign = "Expected '=' after variable.",

    ExpAssign = "Expected an expression after '='.",

    ExpElseIf = "Expected an expression after 'elseif'.",

    ThenElseIf = "Expected 'then' in elseif statement.",

    OpExp = "Expected an expression after operator.",

    NameColonExpSuf = "Expected a method name after ':'.",

    FuncArgsExpSuf = "Expected a list of arguments.",

    NameNamedArg = "Expected a named argument of the form 'name = expression'.",

    AssignNamedArg = "Expected '=' after named argument name.",

    ExpNamedArg = "Expected an expression after '=' in named argument.",

    RCurlyNamedArgs = "Expected '}' to close named argument list.",

    ExpExpSuf = "Expected an expression after '['.",

    RBracketExpSuf = "Expected ']' to match '['.",

    NameDotExpSuf = "Expected a function name after '.'.",

    ExpSimpleExp = "Expected an expression after '('.",

    RParSimpleExp = "Expected ')'to match '('.",

    RParFuncArgs = "Expected ')' to match '('.",

    ExpExpList = "Expected an expression after ','.",

    ExpVarList = "Expected a destination for an assignment after ','.",

    RCurlyInitList = "Expected '{' to match '}'.",

    ExpFieldList = "Expected an expression after ',' or ';'.",

    ExpStat = "Expected a statement but found an expression that is not a function call.",

    AssignNotLValue = "Expected a valid lvalue in the left side of assignment but found a regular expression.",

    CastMissingType = "Expected a type for the cast expression.",

    IsMissingType = "Expected a type for the type-test expression.",

    QualName = "Expected a qualified type name.",

    NameMethod = "Expected a method name after the colon.",

    ListTooLong = "List exceeds the maximum of 100 elements.",

    --
    -- Foreign function bodies: constructs outside the raw-C subset
    -- (tested in spec/parser_spec.lua)
    --

    ForeignRaise = "Raise statements are not available inside a foreign function.",

    ForeignDefer = "Defer statements are not available inside a foreign function.",

    ForeignCatch = "Catch blocks are not available inside a foreign function.",

    ForeignCase = "Case statements are not available inside a foreign function.",

    ForeignForIn = "Generic for loops are not available inside a foreign function.",

    ForeignLambda = "Anonymous functions are not available inside a foreign function.",

    ForeignConstructor = "Titan constructors are not available inside a foreign function.",

    ForeignMethod = "Method selection with ':' is not available inside a foreign function.",

    ForeignTypeArguments = "Generic type arguments are not available inside a foreign function.",

    ForeignDots = "Variadic and spread expressions are not available inside a foreign function.",

    ForeignRange = "Range expressions are not available inside a foreign function.",

    ForeignIs = "Titan type tests are not available inside a foreign function.",

    ForeignCountedCast = "The counted cast 'as T(n)' is not available inside a foreign function; write ';' after the cast if a parenthesized statement follows.",

    ForeignOr = "Titan operator 'or' is not available inside a foreign function.",

    ForeignAnd = "Titan operator 'and' is not available inside a foreign function.",

    ForeignConcat = "Titan operator '..' is not available inside a foreign function.",

    ForeignNot = "Titan operator 'not' is not available inside a foreign function.",

    ForeignOption = "Option declarations and types ('?') are not available inside a foreign function.",

    ForeignReturnList = "A foreign function return statement can return at most one value.",

    ForeignBodyForeign = "Types inside a foreign function body are C types: delete 'foreign' before this type.",

    ForeignBodyOwned = "Owned types are not available inside a foreign function.",

    ForeignBodyTitanType = "Titan Array and Map types are not available inside a foreign function.",

}

syntax_errors.errors = errors

return syntax_errors

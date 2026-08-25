-- C99 grammar written in lpeg.re.
-- Adapted and translated from plain LPeg grammar for C99
-- written by Wesley Smith https://github.com/Flymir/ceg
--
-- Copyright (c) 2009 Wesley Smith
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

-- Reference used in the original and in this implementation:
-- http://www.open-std.org/JTC1/SC22/wg14/www/docs/n1124.pdf

local c99 = {}

local re = require("relabel")
local typed = require("c-parser.typed")

local defs = {}

local location = require("titan-compiler.location")

c99.tracing = false

defs["trace"] = function(s, i)
    if c99.tracing then
        local line, col = location.get_line_number(s, i)
        print("TRACE", line, col, "[[" .. s:sub(i, i + 256):gsub("\n.*", "") .. "]]")
    end
    return true
end

local typedefs = {}

-- Parser-private classification for expressions which were recognized through
-- unaryExpression. C assignment syntax requires every operand to the left of
-- an assignment operator to have that form. Keeping the marker out-of-band
-- preserves the public AST while allowing the factored assignment rule to
-- retain the old syntactic restriction without reparsing its recursive prefix.
local assignment_lhs = {}

-- Number of top-level declarations skipped by the error-recovery rule during the
-- last match_language_grammar call (see the `recover` rule). Exposed as
-- c99.recoveries so callers can report how many declarations were not understood.
local recoveries = 0

-- Furthest end of the leading declaration-specifier run explored by the
-- current top-level declaration attempt. LPeg does not roll match-time side
-- effects back with an ordered choice, which is useful here: if both the
-- function-definition and declaration branches fail after walking the same
-- long prefix, recovery can advance over that already-proven prefix once.
local recovery_specifier_end

local function elem(xs, e)
    for _, x in ipairs(xs) do
        if e == x then
            return true
        end
    end
    return false
end

defs["decl_func"] = typed("string, number, table -> boolean, Decl", function(_, _, decl)
    typed.set_type(decl, "Decl")
    return true, decl
end)

-- Match-time action for the error-recovery rule: count the skipped token/unit
-- and succeed without producing a capture (so it contributes nothing to the
-- translation unit's declaration list).
defs["recover"] = function(_, _)
    recoveries = recoveries + 1
    return true
end

defs["begin_external_declaration"] = function(_, _)
    recovery_specifier_end = nil
    return true
end

defs["note_external_specifier"] = function(_, position)
    if not recovery_specifier_end or position > recovery_specifier_end then
        recovery_specifier_end = position
    end
    return true
end

defs["recover_external_specifiers"] = function(_, position)
    if recovery_specifier_end and recovery_specifier_end >= position then
        recoveries = recoveries + 1
        return recovery_specifier_end
    end
    return false
end

-- Match-time action used to drop a rule's captures: succeeds (keeping the match
-- and its consumed input) but produces no value, so nothing leaks into an
-- enclosing table capture.
defs["discard"] = function(_, _)
    return true
end

defs["decl_ids"] = typed("string, number, table -> boolean, Decl?", function(_, _, decl)
    -- store typedef
    if elem(decl.spec, "typedef") then
        if not (decl.ids and decl.ids[1] and decl.ids[1].decl) then
            return true
        end
        for _, id in ipairs(decl.ids) do
            local name = id.decl.name or id.decl.declarator.name
            if name then
                typedefs[name] = true
            end
        end
    end
    typed.set_type(decl, "Decl")
    return true, decl
end)

defs["is_typedef"] = function(_, _, id)
    -- The former copied scope normalized every truthy member to `true` and did
    -- not consult a caller metatable. Preserve that public set behavior while
    -- borrowing the table: LPeg match-time success must never receive an
    -- arbitrary truthy value as its next-position result.
    local present = not not rawget(typedefs, id)
    return present, present and id
end

defs["empty_table"] = function()
    return true, {}
end

-- Flatten nested expression tables
defs["nest_exp"] = typed("string, number, {Exp} -> boolean, Exp", function(_, _, exp)
    typed.set_type(exp, "Exp")
    if not exp.op then
        return true, exp[1]
    end
    return true, exp
end)

-- Assignment operators associate from right to left. Capture the whole chain
-- once and fold it after the match instead of recursively retrying the complete
-- unary-expression prefix before falling back to a conditional expression.
-- The old ordered choice made nested non-assignment parentheses exponential.
defs["fold_assignment"] = function(_, _, items)
    if #items == 1 then
        return true, items[1]
    end

    for operator_index = 2, #items - 1, 2 do
        if not assignment_lhs[items[operator_index - 1]] then
            return false
        end
    end

    local rhs = items[#items]
    for index = #items - 1, 2, -2 do
        local exp = {
            items[index - 1],
            rhs,
            op = items[index],
        }
        typed.set_type(exp, "Exp")
        rhs = exp
    end
    return true, rhs
end

defs["mark_assignment_lhs"] = function(_, _, exp)
    assignment_lhs[exp] = true
    return true, exp
end

-- Primary expression tables
defs["prim_exp"] = typed("string, number, {string} -> boolean, Exp", function(_, _, exp)
    typed.set_type(exp, "Exp")
    return true, exp
end)

-- Type tables
defs["type_exp"] = typed("string, number, table -> boolean, Exp", function(_, _, exp)
    typed.check(exp[1], "Type")
    typed.set_type(exp, "Exp")
    return true, exp
end)

-- The ordinary standalone expression grammar deliberately has no typedef
-- context and therefore cannot distinguish a parenthesized identifier from a
-- cast. Typed object-like macro parsing supplies that context explicitly. Keep
-- the historical positional cast shape while marking its two roles so callers
-- never have to infer a cast from an otherwise ambiguous two-element table.
defs["typed_cast_exp"] = function(_, _, exp)
    exp.cast_type = exp[1]
    exp.cast_operand = exp[2]
    typed.set_type(exp, "Exp")
    return true, exp
end

-- Types
defs["type"] = typed("string, number, table -> boolean, Type", function(_, _, typ)
    typed.set_type(typ, "Type")
    return true, typ
end)

defs["join"] = typed("string, number, {array} -> boolean, array", function(_, _, xss)
    -- xss[1] .. xss[2]
    if xss[2] then
        table.move(xss[2], 1, #xss[2], #xss[1] + 1, xss[1])
    end
    return true, xss[1] or {}
end)

defs["postfix"] = typed("string, number, table -> boolean, table", function(_, _, pf)
    typed.check(pf[1], "Exp")
    if pf.postfix ~= "" then
        pf[1].postfix = pf.postfix
    end
    return true, pf[1]
end)

defs["litstruct"] = typed("string, number, number -> boolean, string", function(_, _, _)
    return true, "litstruct"
end)

defs["inline_union_member"] = function(_, _, member)
    if member.ids then
        member.type = { member.union }
        for _, specifier in ipairs(member.tail) do
            member.type[#member.type + 1] = specifier
        end
    else
        -- The ordinary struct-declaration production requires declarators
        -- whenever anything follows the inline union specifier. Only the
        -- bare body may use C's anonymous-union member form.
        if #member.tail > 0 then return false end
        member.type = member.union
    end
    member.union = nil
    member.tail = nil
    return true, member
end

--==============================================================================
-- Lexical Rules (used in both preprocessing and language processing)
--==============================================================================

local lexical_rules = [[--lpeg.re

TRACE <- ({} => trace)

empty <- ("" => empty_table)

--------------------------------------------------------------------------------
-- Identifiers

MACRONAME <- { identifierNondigit (identifierNondigit / [0-9])* }
IDENTIFIER <- MACRONAME _
identifierNondigit <- [a-zA-Z_]
                    / universalCharacterName

identifierList <- {| IDENTIFIER ("," _ IDENTIFIER)* |}

--------------------------------------------------------------------------------
-- Universal Character Names

universalCharacterName <- "\u" hexQuad
                        / "\U" hexQuad hexQuad
hexQuad <- hexDigit^4

--------------------------------------------------------------------------------
-- String Literals

STRING_LITERAL <- { ('"' / 'L"') sChar* '"' } _

sChar <- (!["\%nl] .) / escapeSequence

--------------------------------------------------------------------------------
-- Escape Sequences

escapeSequence <- simpleEscapeSequence
                / octalEscapeSequence
                / hexEscapeSequence
                / universalCharacterName

simpleEscapeSequence <- "\" ['"?\abfnrtv]

octalEscapeSequence <- "\" [0-7] [0-7]^-2

hexEscapeSequence <- "\x" hexDigit+

--------------------------------------------------------------------------------
-- Constants

INTEGER_CONSTANT <- { ( hexConstant integerSuffix?
                    / octalConstant integerSuffix?
                    / decimalConstant integerSuffix?
                    ) } _

decimalConstant <- [1-9] digit*
octalConstant <- "0" [0-7]*
hexConstant <- ("0x" / "0X") hexDigit+

digit <- [0-9]
hexDigit <- [0-9a-fA-F]

integerSuffix <- unsignedSuffix longLongSuffix
               / unsignedSuffix longSuffix?
               / longLongSuffix unsignedSuffix?
               / longSuffix unsignedSuffix?

unsignedSuffix <- [uU]
longSuffix <- [lL]
longLongSuffix <- "ll" / "LL"

FLOATING_CONSTANT <- { ( decimalFloatingConstant
                       / hexFloatingConstant
                       ) } _

decimalFloatingConstant <- fractionalConstant exponentPart? floatingSuffix?
                         / digit+ exponentPart floatingSuffix?

hexFloatingConstant <- ("0x" / "0X" ) ( hexFractionalConstant binaryExponentPart floatingSuffix?
                                      /  hexDigit+ binaryExponentPart floatingSuffix? )

fractionalConstant <- digit* "." digit+
                    / digit "."

exponentPart <- [eE] [-+]? digit+

hexFractionalConstant <- hexDigit+? "." hexDigit+
                       / hexDigit+ "."

binaryExponentPart <- [pP] digit+

floatingSuffix <- [flFL]

CHARACTER_CONSTANT <- { ("'" / "L'") cChar+ "'" } _

cChar <- (!['\%nl] .) / escapeSequence

enumerationConstant <- IDENTIFIER

]]

local common_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Common Expression Rules

multiplicativeExpression <- {| castExpression           ({:op: [*/%]                     :} _ castExpression                        )* |} => nest_exp
additiveExpression       <- {| multiplicativeExpression ({:op: [-+]                      :} _ multiplicativeExpression              )* |} => nest_exp
shiftExpression          <- {| additiveExpression       ({:op: ("<<" / ">>")             :} _ additiveExpression                    )* |} => nest_exp
relationalExpression     <- {| shiftExpression          ({:op: (">=" / "<=" / "<" / ">") :} _ shiftExpression                       )* |} => nest_exp
equalityExpression       <- {| relationalExpression     ({:op: ("==" / "!=")             :} _ relationalExpression                  )* |} => nest_exp
bandExpression           <- {| equalityExpression       ({:op: "&"                       :} _ equalityExpression                    )* |} => nest_exp
bxorExpression           <- {| bandExpression           ({:op: "^"                       :} _ bandExpression                        )* |} => nest_exp
borExpression            <- {| bxorExpression           ({:op: "|"                       :} _ bxorExpression                        )* |} => nest_exp
andExpression            <- {| borExpression            ({:op: "&&"                      :} _ borExpression                         )* |} => nest_exp
orExpression             <- {| andExpression            ({:op: "||"                      :} _ andExpression                         )* |} => nest_exp
conditionalExpression    <- {| orExpression             ({:op: "?"                       :} _ expression ":" _ conditionalExpression)? |} => nest_exp

constantExpression <- conditionalExpression

]]

--==============================================================================
-- Language Rules (Phrase Structure Grammar)
--==============================================================================

local language_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- External Definitions

translationUnit <- %s* {| (externalDeclaration / recover)* |} "$EOF$"

externalDeclaration <- ({} => begin_external_declaration)
                       ( staticAssertDeclaration
                       / functionDefinition
                       / externalOrdinaryDeclaration
                       )

-- Error recovery: system headers (e.g. GCC's SIMD intrinsics pulled in via
-- SDL's <SDL_cpuinfo.h>) contain declarations this C99 grammar does not model.
-- Rather than fail the whole header, skip a single token (or `;`, or a balanced
-- `{...}`/string/char consumed atomically) and let translationUnit retry
-- externalDeclaration -- so recovery resyncs at the very next declaration it can
-- parse instead of over-running to the next `;` (which would swallow a good
-- following declaration), and a dangling fragment at end-of-input is dropped
-- rather than failing the whole parse. The generated C still #includes the real
-- header, so only the types Titan references must be understood here;
-- c99.recoveries counts the skipped items.
recover <- (recoverItem ({} => recover_external_specifiers)) => discard
         / recoverItem => recover
recoverItem <- ";" _
             / functionBody
             / stringSkip
             / charSkip
             / (!"$EOF$" (!%s !";" !"{" !"}" !"$EOF$" .)+ %s*)

-- C11 _Static_assert (and the C23 static_assert spelling). The FFI has no use
-- for these, so match and discard -- but consume the message with STRING_LITERAL
-- so its parentheses don't confuse paren matching.
staticAssertDeclaration <- ( ("_Static_assert" / "static_assert") _ "(" _ constantExpression ("," _ STRING_LITERAL+)? ")" _ ";" _ ) => discard

functionDefinition <- {| {:_source_position: {} :} {:spec: {| externalDeclarationSpecifier+ |} :} {:func: declarator :} {:decls: declaration* :} functionBody |} => decl_func

-- The FFI only needs a function's signature, never its body (and headers carry
-- `static inline` definitions whose bodies use the full C statement grammar,
-- inline asm, GNU extensions, Duff's device, ...). Skip the body as a balanced
-- brace group, consuming string/char literals atomically so braces inside them
-- are not miscounted.
functionBody <- "{" _ functionBodyItem* "}" _
functionBodyItem <- functionBody
                  / stringSkip
                  / charSkip
                  / (!"{" !"}" !'"' !"'" .)+
stringSkip <- ('"' / 'L"') sChar* '"' _
charSkip <- ("'" / "L'") cChar+ "'" _

--------------------------------------------------------------------------------
-- Declarations

declaration <- {| {:_source_position: {} :} gccExtensionSpecifier? {:spec: {| declarationSpecifier+ |} :} gccExtensionSpecifier* ({:ids: initDeclarationList :})? gccExtensionSpecifier* ";" _ |} => decl_ids

-- Use a distinct leading-specifier rule only at translation-unit scope. If a
-- declaration attempt fails later, the recovery branch can skip this complete
-- speculative prefix rather than retrying all of its suffixes one token at a
-- time. Nested/block declarations retain the ordinary rule and AST shape.
externalOrdinaryDeclaration <- {| {:_source_position: {} :} gccExtensionSpecifier? {:spec: {| externalDeclarationSpecifier+ |} :} gccExtensionSpecifier* ({:ids: initDeclarationList :})? gccExtensionSpecifier* ";" _ |} => decl_ids

externalDeclarationSpecifier <- declarationSpecifier ({} => note_external_specifier)

declarationSpecifier <- storageClassSpecifier
                      / typeSpecifier
                      / typeQualifier
                      / functionSpecifier

initDeclarationList <- {| initDeclarator ("," _ initDeclarator)* |}

initDeclarator <- {| {:decl: declarator :} ("=" _ {:value: initializer :} )? |}

-- Wrapped in `=> discard`: attribute/asm specifiers carry no type information,
-- so their inner captures (attribute names, asm operands) must not leak as stray
-- positional entries into the enclosing declaration table.
gccExtensionSpecifier <- ( "__attribute__" _ "(" _ "(" _ gccAttributeList ")" _ ")" _
                         / gccAsm
                         / clangAsm
                         / "__DARWIN_ALIAS_STARTING_MAC_1060" _ "(" _ clangAsm ")" _
                         / "__AVAILABILITY_INTERNAL" [a-zA-Z0-9_]+ _ ("(" _ STRING_LITERAL ")" _ )? ) => discard

gccAsm <- "__asm__" _ "(" _ (STRING_LITERAL / ":" _ / expression)+ ")" _

clangAsm <- "__asm" _ "(" _ (STRING_LITERAL / ":" _ / expression)+ ")" _

gccAttributeList <- {| gccAttributeItem ("," _ gccAttributeItem )* |}

gccAttributeItem <- clangAsm
                  / IDENTIFIER ("(" _ (expression ("," _ expression)*)? ")" _)?
                  / ""

storageClassSpecifier <- { "typedef"  } _
                       / { "extern"   } _
                       / { "static"   } _
                       / { "auto"     } _
                       / { "register" } _

typeSpecifier <- typedefName
               / { "void"        } _
               / { "char"        } _
               / { "short"       } _
               / { "int"         } _
               / { "long"        } _
               / { "float"       } _
               / { "double"      } _
               / { "signed"      } _
               / { "unsigned"    } _
               / { "_Bool"       } _
               / { "_Complex"    } _
               / { "__int128_t"  } _
               / { "__uint128_t" } _
               / { "__int128"    } _
               / { "_Float128x"  } _
               / { "_Float128"   } _
               / { "_Float64x"   } _
               / { "_Float64"    } _
               / { "_Float32x"   } _
               / { "_Float32"    } _
               / { "_Float16"    } _
               / { "__float128"  } _
               / { "__float80"   } _
               / structOrUnionSpecifier
               / enumSpecifier

typeQualifier <- { "const"    } _
               / { "restrict" } _
               / { "volatile" } _

functionSpecifier <- { "inline" } _

structOrUnionSpecifier <- {| {:type: structOrUnion :} gccExtensionSpecifier* ({:id: IDENTIFIER :})? "{" _ {:fields: {| structDeclaration+ |} :} "}" _ |}
                        / {| {:type: structOrUnion :} gccExtensionSpecifier* {:id: IDENTIFIER :}                                                     |}

structOrUnion <- { "struct" } _
               / { "union"  } _

-- Parse an inline union body once, then choose whether it is an anonymous
-- member or has ordinary field declarators. The former anonymousUnion / generic
-- choice reparsed the complete body for every named inline-union member, which
-- doubled at each nested member. The guard keeps a malformed exact `union {`
-- prefix from falling back and rebuilding the same recursive body.
inlineUnionMember <- ({| {:union: {| {:type: { "union" } :} _ "{" _ {:fields: {| structDeclaration+ |} :} "}" _ |} :} {:tail: {| specifierQualifier* |} :} ({:ids: structDeclaratorList :})? |} ";" _) => inline_union_member

structDeclaration <- inlineUnionMember
                   / !("union" _ "{") {| {:type: {| specifierQualifier+ |} :} {:ids: structDeclaratorList :} |} ";" _

specifierQualifier <- typeSpecifier
                    / typeQualifier

structDeclaratorList <- {| structDeclarator ("," _ structDeclarator)* |}

structDeclarator <- declarator? ":" _ constantExpression
                  / declarator

enumSpecifier <- {| {:type: enum :} gccExtensionSpecifier* ({:id: IDENTIFIER :})? "{" _ {:values: enumeratorList :} ("," _)? "}" _ |}
               / {| {:type: enum :} gccExtensionSpecifier* {:id: IDENTIFIER :}                                                          |}

enum <- { "enum" } _

enumeratorList <- {| enumerator ("," _ enumerator)* |}

enumerator <- {| {:id: enumerationConstant :} ("=" _ {:value: constantExpression :})? |}

declarator <- {| pointer? directDeclarator |}

directDeclarator <- {:name: IDENTIFIER :} ddRec
                  / "(" _ {:declarator: declarator :} ")" _ ddRec
-- Keep C's old-style empty `()` distinct from a parameter-type-list
-- prototype. The registrar needs this source-level distinction because
-- `(void)` is a known empty name list while `()` publishes no parameter API.
ddRec <- arrayDeclaratorSuffix ddRec
       / "(" _ {:params: parameterTypeList :} {:paramstyle: "" -> "prototype" :} ")" _ ddRec
       / "(" _ {:params: empty :} {:paramstyle: "" -> "oldstyle" :} ")" _ ddRec
       / "(" _ {:params: identifierList :} {:paramstyle: "" -> "oldstyle" :} ")" _ ddRec
       / ""

-- Keep bracket qualifiers and `static` out of the bound capture. A named
-- capture around their whole token sequence retains only its first capture,
-- turning `[static 3]` into the invalid synthetic spelling `[static]`.
-- Canonical consumers may render `static` before the qualifier list: the two
-- source orders have the same adjusted parameter-type meaning.
arrayDeclaratorSuffix <- "[" _ arrayDeclaratorContents "]" _
arrayDeclaratorContents <-
         {| {:array_static: { "static" } :} _ arrayDeclaratorQualifiers? {:idx: assignmentExpression :} |}
       / {| arrayDeclaratorQualifiers {:array_static: { "static" } :} _ {:idx: assignmentExpression :} |}
       / {| arrayDeclaratorQualifiers? {:idx: { "*" } :} _ |}
       / {| arrayDeclaratorQualifiers? ({:idx: assignmentExpression :} / {:idx: "" -> "" :}) |}
arrayDeclaratorQualifiers <- {:array_qualifiers: {| typeQualifier+ |} :}

pointer <- {| ({ "*"/"^" } _ typeQualifier*)+ |}

parameterTypeList <- {| parameterList ("," _ {| { "..." } |} _)? |} => join

parameterList <- {| parameterDeclaration ("," _ parameterDeclaration)* |}

parameterDeclaration <- {| {:param: {| {:type: {| declarationSpecifier+ |} :} {:id: (declarator / abstractDeclarator?) :} |} :} |}

typeName <- {| specifierQualifier+ abstractDeclarator? |} => type

abstractDeclarator <- {| pointer? directAbstractDeclarator |}
                    / pointer

-- Preserve abstract declarators in the same recursive shape as named
-- declarators. The old suffix-only recognizer consumed `(*)[N]` and
-- `(*)(P...)` but captured only the inner `*`, so unnamed parameters silently
-- lost their array/function nesting before CType conversion.
directAbstractDeclarator <- "(" _ {:declarator: abstractDeclarator :} ")" _ daRec
                          / daRecNonempty
daRec <- arrayDeclaratorSuffix daRec
       / "(" _ {:params: parameterTypeList :} {:paramstyle: "" -> "prototype" :} ")" _ daRec
       / "(" _ {:params: empty :} {:paramstyle: "" -> "oldstyle" :} ")" _ daRec
       / ""
daRecNonempty <- arrayDeclaratorSuffix daRec
               / "(" _ {:params: parameterTypeList :} {:paramstyle: "" -> "prototype" :} ")" _ daRec
               / "(" _ {:params: empty :} {:paramstyle: "" -> "oldstyle" :} ")" _ daRec

typedefName <- IDENTIFIER => is_typedef

initializer <- assignmentExpression
             / "{" _ initializerList ("," _)? "}" _

initializerList <- {| initializerList2 ("," _ initializerList2)* |}
initializerList2 <- designation? initializer

designation <- designator+ "=" _

designator <- "[" _ constantExpression "]" _
            / "." _ IDENTIFIER

--------------------------------------------------------------------------------
-- Statements

statement <- labeledStatement
           / compoundStatement
           / expressionStatement
           / selectionStatement
           / iterationStatement
           / jumpStatement
           / gccAsm ";" _

labeledStatement <- IDENTIFIER ":" _ statement
                  / "case" _ constantExpression ":" _ statement
                  / "default" _ ":" _ statement

compoundStatement <- "{" _ blockItem+ "}" _

blockItem <- declaration
           / statement

expressionStatement <- expression? ";" _

selectionStatement <- "if" _ "(" _ expression ")" _ statement "else" _ statement
                    / "if" _ "(" _ expression ")" _ statement
                    / "switch" _ "(" _ expression ")" _ statement

iterationStatement <- "while" _ "(" _ expression ")" _ statement
                    / "do" _ statement "while" _ "(" _ expression ")" _ ";" _
                    / "for" _ "(" _ expression? ";" _ expression? ";" _ expression? ")" _ statement
                    / "for" _ "(" _ declaration expression? ";" _ expression? ")" _ statement

jumpStatement <- "goto" _ IDENTIFIER ";" _
               / "continue" _ ";" _
               / "break" _ ";" _
               / "return" _ expression? ";" _

--------------------------------------------------------------------------------
-- Advanced Language Expression Rules
-- (which require type names)

postfixExpression <- {| {:op: {} => litstruct :} "(" _ {:struct: typeName :} ")" _ "{" _ {:vals: initializerList :} ("," _)? "}" _ peRec |} => nest_exp
                   / {| primaryExpression {:postfix: peRec :} |} => postfix

sizeofOrPostfixExpression <- {| {:op: "sizeof" :} _ "(" _ typeName ")" _ |} => type_exp
                           / {| {:op: "sizeof" :} _ unaryExpression |} => nest_exp
                           / postfixExpression

castExpression <- {| "(" _ typeName ")" _ castExpression |} => typed_cast_exp
                / unaryExpression

]]

--==============================================================================
-- Language Expression Rules
--==============================================================================

local language_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Language Expression Rules
-- (rules which differ from preprocessing stage)

expression <- {| assignmentExpression ({:op: "," :} _ assignmentExpression)* |} => nest_exp

constant <- ( FLOATING_CONSTANT
            / INTEGER_CONSTANT
            / CHARACTER_CONSTANT
            / enumerationConstant
            )

primaryExpression <- {| constant |} => prim_exp
                   / {| IDENTIFIER |} => prim_exp
                   / {| STRING_LITERAL+ |} => prim_exp
                   / "(" _ expression ")" _

peRec <- {| "[" _ {:idx: expression :} "]" _ peRec |}
       / {| "(" _ {:args: argumentExpressionList / empty :} ")"  _ peRec |}
       / {| "." _ {:dot: IDENTIFIER :} peRec |}
       / {| "->" _ {:arrow: IDENTIFIER :} peRec |}
       / {| "++" _ peRec |}
       / {| "--" _ peRec |}
       / ""

argumentExpressionList <- {| assignmentExpression ("," _ assignmentExpression)* |}

unaryExpression <- ( {| {:op: prefixOp :} unaryExpression     |} => nest_exp
                   / {| {:op: unaryOperator :} castExpression  |} => nest_exp
                   / sizeofOrPostfixExpression
                   ) => mark_assignment_lhs

prefixOp <- { "++" } _
          / { "--" } _

unaryOperator <- { [-+~!*&] } _

assignmentExpression <- {| conditionalExpression (assignmentOperator conditionalExpression)* |} => fold_assignment

assignmentOperator <- { "="
                      / "*="
                      / "/="
                      / "%="
                      / "+="
                      / "-="
                      / "<<="
                      / ">>="
                      / "&="
                      / "^="
                      / "|=" } _

--------------------------------------------------------------------------------
-- Language whitespace

_ <- %s+
S <- %s+

]]

local simplified_language_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Simplified Language Expression Rules
-- (versions that do not require knowledge of type names)

postfixExpression <- {| primaryExpression {:postfix: peRec :} |} => postfix

sizeofOrPostfixExpression <- postfixExpression

castExpression <- unaryExpression

]]

local typed_language_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Typedef-aware Language Expression Rules
--
-- This leading rule selects the complete language grammar below as an
-- expression parser and requires the complete subject to be one expression.
-- Object-like macro registration must not accept a valid prefix and silently
-- ignore trailing replacement tokens.

typedExpression <- expression !.

]]

--==============================================================================
-- Preprocessing Rules
--==============================================================================

local preprocessing_rules = [[--lpeg.re

preprocessingLine <- _ ( ("#" / "%:") _ directive _
                       / ("#" / "%:") _ preprocessingTokenList? {| _ |} -- non-directive, ignore
                       / preprocessingTokenList
                       / empty
                       )

preprocessingTokenList <- {| (preprocessingToken _)+ |}

directive <- {| {:directive: "if"      :} S {:exp: preprocessingTokenList :} |}
           / {| {:directive: "ifdef"   :} S {:id: IDENTIFIER :} |}
           / {| {:directive: "ifndef"  :} S {:id: IDENTIFIER :} |}
           / {| {:directive: "elif"    :} S {:exp: preprocessingTokenList :} |}
           / {| {:directive: "else"    :} |}
           / {| {:directive: "endif"   :} |}
           / {| {:directive: "include" :} S {:exp: headerName :} |}
           / {| {:directive: "define"  :} S {:id: MACRONAME :} "(" _ {:args: defineArgList :} _ ")" _ {:repl: replacementList :} |}
           / {| {:directive: "define"  :} S {:id: MACRONAME :} _ {:repl: replacementList :} |}
           / {| {:directive: "undef"   :} S {:id: IDENTIFIER :} |}
           / {| {:directive: "line"    :} S {:line: preprocessingTokenList :} |}
           / {| {:directive: "error"   :} S {:error: preprocessingTokenList / empty :} |}
           / {| {:directive: "error"   :} |}
           / {| {:directive: "pragma"  :} S {:pragma: preprocessingTokenList / empty :} |}
           / gccDirective
           / ""

gccDirective <- {| {:directive: "include_next" :} S {:exp: headerName :} |}
              / {| {:directive: "warning" :} S {:exp: preprocessingTokenList / empty :} |}

defineArgList <- {| { "..." } |}
               / {| identifierList _ "," _ {| { "..." } |} |} => join
               / identifierList
               / empty

replacementList <- {| (preprocessingToken _)* |}

preprocessingToken <- preprocessingNumber
                    / CHARACTER_CONSTANT
                    / STRING_LITERAL
                    / punctuator
                    / IDENTIFIER
                    / otherToken

-- C "each non-white-space character that cannot be one of the above" pp-token
-- (C99 6.4p1). Without this, a stray char (@, $, `), an unterminated or empty
-- string/char literal, etc. would stop the token list early and silently drop
-- the rest of the logical line; instead we pass the character through verbatim.
otherToken <- { !%s . }

headerName <- {| {:mode: "<" -> "system" :} { (![%nl>] .)+ } ">" |}
            / {| {:mode: '"' -> "quote" :} { (![%nl"] .)+ } '"' |}
            / {| IDENTIFIER |} -- macro

preprocessingNumber <- { ("."? digit) ( digit
                                      / [eEpP] [-+]
                                      / identifierNondigit
                                      / "."
                                      )* }

-- `digraphs` already produces the canonical replacement capture. Keep it
-- outside the ordinary substring capture; wrapping both used to emit two
-- preprocessing tokens (the raw `%:` plus `#`, `<:` plus `[`, and so on).
punctuator <- digraphs
            / { '...' / '<<=' / '>>=' /
                '##' / '<<' / '>>' / '->' / '++' / '--' / '&&' / '||' / '<=' / '>=' /
                '==' / '!=' / '*=' / '/=' / '%=' / '+=' / '-=' / '&=' / '^=' / '|=' /
                '#' / '[' / ']' / '(' / ')' / '{' / '}' / '.' / '&' /
                '*' / '+' / '-' / '~' / '!' / '/' / '%' / '<' / '>' /
                '^' / '|' / '?' / ':' / ';' / ',' / '=' }

digraphs <- '%:%:' -> "##"
          / '%:' -> "#"
          / '<:' -> "["
          / ':>' -> "]"
          / '<%' -> "{"
          / '%>' -> "}"

--------------------------------------------------------------------------------
-- Preprocessing whitespace

_ <- %s*
S <- %s+

]]

--==============================================================================
-- Preprocessing Expression Rules
--==============================================================================

local preprocessing_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Preprocessing Expression Rules
-- (rules which differ from language processing stage)

expression <- constantExpression

constant <- FLOATING_CONSTANT
          / INTEGER_CONSTANT
          / CHARACTER_CONSTANT

primaryExpression <- {| IDENTIFIER |} => prim_exp
                   / {| constant |} => prim_exp
                   / "(" _ expression _ ")" _

postfixExpression <- primaryExpression peRec
peRec <- "(" _ (argumentExpressionList / empty) ")" _ peRec
       / ""

argumentExpressionList <- {| expression ("," _ expression )* |}

unaryExpression <- {| {:op: unaryOperator :} unaryExpression |} => nest_exp
                 / primaryExpression

unaryOperator <- { [-+~!] } _
               / { "defined" } _

castExpression <- unaryExpression

--------------------------------------------------------------------------------
-- Preprocessing expression whitespace

_ <- %s*
S <- %s+

]]

local preprocessing_grammar = re.compile(
    preprocessing_rules ..
    lexical_rules, defs)

local preprocessing_expression_grammar = re.compile(
    preprocessing_expression_rules ..
    lexical_rules ..
    common_expression_rules, defs)

local language_expression_grammar = re.compile(
    language_expression_rules ..
    simplified_language_expression_rules ..
    lexical_rules ..
    common_expression_rules, defs)

local typed_language_expression_grammar = re.compile(
    typed_language_expression_rules ..
    language_rules ..
    language_expression_rules ..
    lexical_rules ..
    common_expression_rules, defs)

local language_grammar = re.compile(
    language_rules ..
    language_expression_rules ..
    lexical_rules ..
    common_expression_rules, defs)

local function match(grammar, subject)
    -- pcall so a pathologically nested input (LPeg "backtrack stack overflow",
    -- e.g. hundreds of nested braces/parens in a system header) surfaces as a
    -- clean parse failure instead of raising out of the FFI.
    local ok, res, err, pos = pcall(grammar.match, grammar, subject)
    if not ok then
        return nil, tostring(res), 1, 1, ""
    end
    if res == nil then
        local l, c = re.calcline(subject, pos)
        local fragment = subject:sub(pos, pos + 20)
        return res, err, l, c, fragment
    end
    return res
end

function c99.match_language_grammar(subject)
    typedefs = {}
    assignment_lhs = {}
    recoveries = 0
    recovery_specifier_end = nil
    local res, err, l, c, fragment = match(language_grammar, subject)
    assignment_lhs = {}
    recovery_specifier_end = nil
    c99.recoveries = recoveries
    return res, err, l, c, fragment
end

function c99.match_language_expression_grammar(subject)
    assignment_lhs = {}
    local results = table.pack(match(language_expression_grammar, subject))
    assignment_lhs = {}
    return table.unpack(results, 1, results.n)
end

function c99.match_typed_language_expression_grammar(subject, typedef_names)
    local previous_typedefs = typedefs
    -- This grammar only reads typedef names through is_typedef; declaration
    -- rules that populate the map are unreachable from typedExpression. Borrow
    -- the caller's immutable map for this synchronous match instead of copying
    -- every typedef for every object-like macro in a header.
    typedefs = typedef_names or {}
    assignment_lhs = {}
    local results = table.pack(match(
        typed_language_expression_grammar, subject))
    assignment_lhs = {}
    typedefs = previous_typedefs
    return table.unpack(results, 1, results.n)
end

function c99.match_preprocessing_grammar(subject)
    return match(preprocessing_grammar, subject)
end

function c99.match_preprocessing_expression_grammar(subject)
    return match(preprocessing_expression_grammar, subject)
end

return c99

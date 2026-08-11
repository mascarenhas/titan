# Named arguments

Named arguments are a checker elaboration over Titan's existing positional
call machinery. The parser preserves the delimiter and lexical field order;
the checker proves that the callee is an eligible declaration, matches labels,
and rewrites the arguments into a dense positional list; the coder freezes
explicit expressions in lexical order before emitting the unchanged native or
direct-C call.

The language contract is in
[Named arguments](../language/named-arguments.md). This chapter follows the
implementation from source syntax through interface metadata and generated C.

## Parser and AST boundary

`parser.lua` deliberately has four call-argument node shapes:

```text
ArgsFunc       { args }
ArgsMethod     { method, args }
ArgsNamedFunc  { fields }
ArgsNamedMethod{ method, fields }
```

`funcargs` accepts a parenthesized expression list or a bare string. A separate
`namedargs` production accepts braces and only `NAMEDLABEL '=' exp` fields,
with comma or semicolon separators and an optional trailing separator. Because
`NAMEDLABEL` is reachable only in that production, it can recognize the raw
identifier spelling of a Titan keyword without weakening `NAME` anywhere else.
There is no whitespace-sensitive alternative: `f{}` and `f {}` take the same
suffix path.

Braces were removed from `funcargs`. Consequently, `f { x = 1 }` always
produces `ArgsNamedFunc`; a constructor passed positionally is represented by
the ordinary parenthesized path in `f({ x = 1 })`. The parser's suffix closures
are `suffix_namedfunccall` and `suffix_namedmethodcall`. Named entries reuse
`Ast.Field {name, exp}` nodes, but the enclosing `ArgsNamed*` tag keeps them
distinct from an `ExpInitList` record constructor.

These named shapes are intentionally temporary. Error-recovery helpers such as
`call_argument_expressions` understand all four tags, but a successfully
checked call is normalized to `ArgsFunc` or `ArgsMethod` before code generation.

## Declaration metadata, not function types

Formal names are attached only to descriptors for declarations:

```text
Type.ModuleMember(..., type, paramnames)
Type.Method(..., varargtype, flexrettype, paramnames)
Type.StaticMethod(..., varargtype, flexrettype, paramnames)
```

`TopLevelFunc` keeps its dense fixed-parameter name list in `_paramnames`.
Methods and user-declared record/union statics store the list in their
descriptor; the implicit
method receiver and the trailing variadic marker are excluded.

`Type.Function` and `Type.CFunction` have not gained a names field. Their
equality, callable adjustment, string rendering, serialization, and
first-class function tags therefore remain structural. This enforces the
feature boundary: a direct declaration can publish names while a function
value, anonymous closure, bound-method value, or C function pointer cannot
acquire named-call eligibility merely from its function type.

An Interface method is one of those declaration descriptors. Direct
`wrapper:method { ... }` checking uses the Interface method's `paramnames`,
while structural satisfaction compares self-removed `Type.Function` shapes
and deliberately ignores the concrete method's spellings. The checker lowers
the named Interface call to Interface-slot positions before any exact or
adjusted dispatch. A bound Interface method remains a first-class function
value and is therefore positional-only, like every other bound method.

### Compiled Titan interfaces

`types.serialize` includes `paramnames` in exported `ModuleMember`, `Method`,
and `StaticMethod` constructor expressions. It uses quoted Lua string literals
for every spelling and preserves the difference between `{}` (a known
zero-parameter declaration) and `false` (metadata unavailable). The imported
module's `<mangled>_types` function re-evaluates those descriptors through the
normal constructor environment.

Changing those serialized constructor arities is why the compiled-module ABI
advanced from **0.12 to 0.13**. The native function signature and call ABI did
not change. Loader code checks `<mangled>_abi` before it evaluates
`<mangled>_types`, so an old 0.12 DSO is rejected as an ABI mismatch instead of
being interpreted with the new descriptor constructors.

Callable types now also carry `flexrettype`, and Method/StaticMethod constructor
expressions serialize it before `paramnames`. That is a separate interface
shape and native-signature change, shipped under ABI 0.14 rather than teaching
0.13 to accept both schemas.

## C prototype metadata

The foreign-import pipeline deliberately splits type and declaration metadata:

```text
c99 declarator -> CType declaration -> foreigntypes conversion -> member.type
                               `-----> copied by checker -----> member.paramnames
```

`c-parser/c99.lua` records `paramstyle = "prototype"` for a prototype with a
typed parameter list, including `(void)`, and `"oldstyle"` for `()`. In
`ctypes.lua`, `get_params` collects names from effective non-void fixed
parameters. It publishes a table only if every name is present and unique;
otherwise it publishes `false`. Thus `(void)` produces `{}`, while `()` does
not claim a known empty interface.

Compatible C redeclarations still compare by C type, never by spelling.
After that comparison, `merge_paramnames` maintains a declaration-local state:

* `unknown` can be upgraded by a complete later prototype;
* an incomplete or unnamed redeclaration cannot erase a complete list;
* two different complete lists make the declaration permanently
  `conflicting`, represented externally as `paramnames = false`.

This merge is order-safe for the descriptor retained by `ctypes.register_types`.
`foreigntypes.convert` continues to erase names from structural
`Type.CFunction` values, including callback typedefs. Only the checker-created
direct foreign `Type.ModuleMember` copies the raw C function declaration's
`paramnames` field.

## Checker elaboration

`checkexp` first resolves the call target as before, then uses the original
`ArgsNamed*` tag to enter named checking. Eligibility is provenance-based:

* `Ast.TopLevelFunc` provides `_paramnames`;
* `Type.StaticMethod` and a Titan `Type.ModuleMember` provide their serialized
  `paramnames`;
* a direct member of `Type.CModule` is recognized as the foreign lowering and
  may provide a complete C list;
* a record method uses `Type.Method.paramnames`, with `self` already excluded.

Generated union variant constructors are the deliberate nominal-static
exception. Their parser-synthesized parameter is an implementation detail, so
the checker publishes `paramnames = false` even for a payload variant. They
remain first-class fixed Titan functions and use ordinary positional
adjustment, but a brace-delimited call is rejected as unavailable named
metadata. User-declared union functions follow the same named-call rules as
record functions.

All structural function-value paths, C function-pointer calls, C pseudo
constructors, input-variadic Titan declarations, and C variadic declarations
are rejected before lowering. A declaration with a flexible *result* tail is
still eligible because result shape does not make the label-to-fixed-parameter
mapping ambiguous. A direct foreign declaration with `paramnames = false` gets the
specific unavailable-prototype diagnostic rather than a series of unknown-name
errors.

`check_named_args` builds a name-to-formal-index map, then visits explicit
fields in lexical order. Each expression is checked with its matched formal as
context, passed through `trycoerce`, and consumed under a finite one-result
demand. If that slot reaches a flexible tail, the projection is `T?` (then
follows the ordinary coercion/unwrap rules); a declared fixed first result
keeps its fixed type. The expression never expands into later named fields.
Unknown and duplicate names are reported at their fields. The helper returns:

1. a dense array indexed in formal order; and
2. an `order` array containing the formal index of each accepted explicit
   expression in lexical order.

For every absent formal it synthesizes `Ast.ExpNil`, accepts it only when
`nil_can_adjust_to` succeeds, applies the ordinary coercion, and marks the
result `_named_omitted = true`. The checked call then receives
`_named_arg_order = order` and `_named_call_kind = "titan"` or `"foreign"`,
while its payload is replaced with `ArgsFunc` or `ArgsMethod`. Downstream call
classification and native signatures therefore remain positional.

## Code generation and evaluation order

For a static Titan call, `codecall` uses `named_ordered_call_args` when
`_named_arg_order` is present. That helper generates every explicit expression
in recorded lexical order and immediately freezes it in an untraced C temporary.
It freezes synthetic omissions afterward and returns expressions indexed by
formal position. The existing `codecall` loop emits those C values into the
ordinary positional native call.

Immediate C-only freezing is essential: `codeexp` can produce deferred C
expressions, so merely iterating in source order and later printing them in
formal order would reorder effects. It deliberately does **not** give
GC-bearing inputs tracing-only call slots. For methods, `codecall` freezes the
receiver once before invoking `named_ordered_call_args`, matching the language
order of receiver first, then written arguments.

`codeforeigncall` has a parallel path. For each explicit named argument in
lexical order, it runs `codeforeignexp`, assigns the converted result to a C
temporary of the formal's target type, and records that temporary by formal
index. It freezes omissions afterward, emits the C argument list in formal
order, and retains `mutable_out_anchor` refreshes after the call. That last step
is required for GC-bearing mutable `TValue` out parameters just as on the
positional path.

Neither path emits a name table, changes the native signature, or enters
`codevaluecall`/`luaD_callnoyield` for an eligible direct call.

## Record missing-field synthesis

Context-typed record constructors share the omission policy but remain
`ExpInitList`, not call nodes. After checking explicit visible fields in source
order, the checker walks unsupplied record fields. A nil-compatible field gets
a synthesized, coerced `ExpNil` marked `_named_omitted`, wrapped in an
`Ast.Field` whose `_field` descriptor identifies the target slot, and appended
after all explicit fields. A required field produces the dedicated
cannot-be-omitted diagnostic.

Explicit duplicate fields retain their pre-existing constructor behavior and
are not collapsed by the `supplied` set: code generation evaluates and stores
each explicit entry in source order, so the final store wins. The record-level
visibility check still rejects every `{...}` construction outside the defining
module when the record has any local field, before omission can make private
slots appear fillable.

This record initializer path does not apply to union construction. A record
payload is one positional expression—`Message.move({ x = 1.0, y = 2.0 })`—so
the parentheses distinguish the variant call from the brace-delimited
named-call syntax. Union constructors do not synthesize named omissions; their
fixed positional call path supplies the ordinary nil-fill/surplus adjustment.

## The Lua entry boundary is unchanged

`genluaentry` still consumes Lua stack slots positionally, pads missing Lua
arguments under the existing Titan-function rule, ignores extras for a fixed
function (or collects them for an input-variadic one), and performs the usual
boundary checks. Flexible results follow the caller's requested Lua result
count exactly as they do for positional calls. A Lua table carries no marker
distinguishing a named bundle from an intended table or `value`, so no key
inspection or arity heuristic was added. Named arguments are completely
resolved by Titan's checker before C generation.

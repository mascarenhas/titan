# Named arguments

Named arguments are a checker elaboration over Titan's positional call
machinery. The parser preserves the delimiter and lexical field order; the
checker proves that the callee is an eligible declaration, matches labels, and
rewrites the arguments into a dense positional list; the coder freezes explicit
expressions in lexical order before emitting the unchanged native or direct-C
call. The language contract is in
[Named arguments](../language/named-arguments.md).

## Parser and AST boundary

`ast.lua` has four call-argument node shapes:

```text
ArgsFunc       { args }
ArgsMethod     { method, args }
ArgsNamedFunc  { fields }
ArgsNamedMethod{ method, fields }
```

In `parser.lua`, `callsuffix` selects a parenthesized expression list, braces
containing `namedargs`, or a bare string; `defs.call_suffix` builds the node. A
`namedarg` is `ANYNAME '=' exp`; comma or semicolon separators and a trailing
separator are accepted. `ANYNAME` admits keyword labels and is also used for
member selectors and eligible declaration names. There is no
whitespace-sensitive alternative: `f{}` and `f {}` take the same suffix path.

Thus `f { x = 1 }` always produces `ArgsNamedFunc`; a constructor passed
positionally uses the parenthesized path in `f({ x = 1 })`. Named entries reuse
`Ast.Field {name, exp}` nodes, but the enclosing `ArgsNamed*` tag keeps them
distinct from an `ExpInitList` record constructor.

The named shapes are temporary. Error-recovery helpers such as
`call_argument_expressions` (`checker/variables.lua`) understand all four tags,
but a successfully checked call is normalized to `ArgsFunc` or `ArgsMethod`
before code generation.

## Declaration metadata, not function types

Formal names are attached only to declaration descriptors:

```text
Type.ModuleMember(modname, name, type, paramnames)
Type.Method(fqtn, name, params, rettypes, varargtype, flexrettype, paramnames, ...)
Type.StaticMethod(fqtn, name, params, rettypes, varargtype, flexrettype, paramnames, ...)
```

`Ast.TopLevelFunc` and `Ast.TopLevelForeignFunc` keep their dense
fixed-parameter name list in `_paramnames`, produced by `param_types`
(`checker/common.lua`). Methods and record/union statics store the list in
their descriptor. The implicit method receiver and the trailing variadic marker
are excluded.

`Type.Function` and `Type.CFunction` carry no names. Boxed `Type.Function`
equality, adjustment and tags stay structural, while `Type.CFunction` keeps
separate C signature identity and is never a boxed callable. This is the
feature boundary: a direct foreign `Type.ModuleMember` can retain an
authoritative `CFunction` plus declaration names, while a function value,
anonymous closure, bound-method value, or C function pointer cannot acquire
named-call eligibility from its type.

An Interface method is one of those declaration descriptors. Direct
`wrapper:method { ... }` checking uses the Interface method's `paramnames`,
while structural satisfaction compares self-removed `Type.Function` shapes and
ignores the concrete method's spellings. The checker lowers the named Interface
call to Interface-slot positions before any exact or adjusted dispatch. A bound
Interface method is a first-class function value and is therefore
positional-only, like every other bound method.

### Compiled Titan interfaces

`types.serialize` (`serialize_names`) includes `paramnames` in exported
`ModuleMember`, `Method`, and `StaticMethod` constructor expressions. It emits
quoted Lua string literals and preserves the difference between `{}` (a known
zero-parameter declaration) and `nil` (metadata unavailable). The imported
module's `<mangled>_types` function re-evaluates those descriptors through the
normal constructor environment. The serialized constructor shapes are
ABI-visible even though the native call ABI does not depend on names; loader
code checks `<mangled>_abi` before it evaluates `<mangled>_types`. The full
callable schema is in
[flexible-return internals](flexible-returns.md#serialization-and-abi-boundary).

## C prototype metadata

The foreign-import pipeline splits type and declaration metadata:

```text
c99 declarator -> CType declaration -> foreigntypes conversion -> member.type
                               `-----> copied by checker -----> member.paramnames
```

`c-parser/c99.lua` records `paramstyle = "prototype"` for a prototype with a
typed parameter list, including `(void)`, and `"oldstyle"` for `()`. In
`c-parser/ctypes.lua`, `get_params` collects names from effective non-void fixed
parameters. It publishes a table only if every name is present and unique;
otherwise it publishes `nil`. Thus `(void)` produces `{}`, while `()` does not
claim a known empty interface.

Compatible C redeclarations still compare by C type, never by spelling. After
that comparison, `ctypes.lua` `merge_paramnames` maintains a declaration-local
`paramnames_state`:

* `unknown` can be upgraded by a complete later prototype;
* an incomplete or unnamed redeclaration cannot erase a complete list;
* two different complete lists make the declaration permanently
  `conflicting`, represented externally as `paramnames = nil`.

`foreigntypes.convert` erases names from structural `Type.CFunction` values,
including callback typedefs. Only the checker-created `ffi` namespace member
(`checker/declarations.lua`, via `copy_foreign_paramnames` in
`checker/c_types.lua`) copies the raw C function declaration's `paramnames`.

## Checker elaboration

`checkexp` first resolves the call target, then uses the original `ArgsNamed*`
tag to enter named checking. Eligibility is provenance-based and lives in
`named_function_metadata` (`checker/variables.lua`):

* `Ast.TopLevelFunc` provides `_paramnames` (Titan lowering);
* `Ast.TopLevelForeignFunc` provides `_paramnames` (foreign lowering);
* `Type.StaticMethod` and a Titan `Type.ModuleMember` (`Function` or
  `FunctionScheme`) provide their serialized `paramnames`;
* a direct foreign `Type.ModuleMember` whose type is `CFunction` provides its
  copied C list, or `nil`.

Record, union, and Interface method calls are handled in the method-call
branch of `checker/expressions.lua` and use `Type.Method.paramnames`, with
`self` already excluded. Generated union-variant constructors are ordinary
`Type.StaticMethod`s: `parser.lua` `defs.uniondecl` synthesizes one parameter
per payload part with the declared part name, and `defs.unionpayload` names an
unnamed single payload `value`.

All structural function-value paths, C function-pointer calls, C pseudo
constructors, input-variadic Titan declarations, and C variadic declarations
are rejected before lowering (`named_target_error` and the specific variadic
diagnostics). A declaration with a flexible *result* tail is still eligible
because result shape does not make the label-to-fixed-parameter mapping
ambiguous. A direct foreign declaration with `paramnames = nil` gets the
specific unavailable-prototype diagnostic rather than a series of unknown-name
errors.

`check_named_args` (`checker/calls.lua`) builds a name-to-formal-index map,
then visits explicit fields in lexical order. Each expression is checked with
its matched formal as context, passed through `coerce_and_check`, and consumed
under a finite one-result demand. If that slot reaches a flexible tail, the
projection is `T?` (then follows the ordinary coercion/unwrap rules); a
declared fixed first result keeps its fixed type. The expression never expands
into later named fields. Unknown and duplicate names are reported at their
fields. The helper returns:

1. a dense array indexed in formal order; and
2. an `order` array containing the formal index of each accepted explicit
   expression in lexical order.

For every absent formal it synthesizes `Ast.ExpNil`, accepts it only when
`types.assignment_adjustment(Nil, formal)` exists, applies the ordinary
coercion, and marks the result `_named_omitted = true`. Otherwise it reports
`parameter '...' of type ... cannot be omitted because it does not accept nil`.

The callers in `checker/expressions.lua` (and the generic path in
`checker/calls.lua`) then set `_named_arg_order = order` and
`_named_call_kind = "titan"` or `"foreign"`, and replace the payload with
`ArgsFunc` or `ArgsMethod`. Downstream call classification and native
signatures therefore remain positional. The written fields remain only on
`_surface_named_args`; each valid label's `_decl` points to its canonical
callable-parameter descriptor (or to the corresponding `Type.Field` for
synthesized record `new`). Separately compiled callers reconstruct parameter
identity from the callable owner/name, fixed index, and serialized
`paramnames`. Semantic tools can therefore navigate and rename the label
without exposing it to codegen, which skips this private source edge.

## Code generation and evaluation order

For a static Titan call, `codecall` (`coder/calls.lua`) uses
`named_ordered_call_args` when `_named_arg_order` is present. That helper
generates every explicit expression in recorded lexical order and immediately
freezes it in an untraced C temporary. It freezes synthetic omissions afterward
and returns expressions indexed by formal position. The existing `codecall`
loop emits those C values into the ordinary positional native call.

Immediate freezing is essential: `codeexp` can produce deferred C expressions,
so iterating in source order and later printing them in formal order would
reorder effects. GC-bearing inputs do not get tracing-only call slots. For
methods, `codecall` freezes the receiver once before invoking
`named_ordered_call_args`, matching the language order of receiver first, then
written arguments.

`codeforeigncall` has a parallel path. For each explicit named argument in
lexical order, it runs `codeforeignexp`, assigns the converted result to a C
temporary of the formal's target type, and records that temporary by formal
index. It freezes omissions afterward, emits the C argument list in formal
order, and keeps the positional path's post-call `mutable_out_anchor`
refreshes for GC-bearing mutable `TValue` out parameters. C's unspecified
argument-evaluation order therefore cannot reorder Titan effects. Restricted
foreign bodies use the same scheme through `_foreign_raw_call`
(`coder/declarations.lua`).

Neither path emits a name table, changes the native signature, or enters
`codevaluecall`/`luaD_callnoyield` for an eligible direct call.

## Record missing-field synthesis

Context-typed record constructors share the omission policy but remain
`ExpInitList`, not call nodes. `generic_finish_named_record_constructor`
(`checker/expression_lists.lua`) checks explicit visible fields in source
order, then walks unsupplied record fields. A field whose type accepts nil gets
a synthesized, coerced `ExpNil` marked `_named_omitted`, wrapped in an
`Ast.Field` whose `_field` descriptor identifies the target slot, and appended
after all explicit fields. Any other field produces the
`field '...' of record '...' cannot be omitted` diagnostic.

Explicit duplicate fields are not collapsed by the `supplied` set: code
generation evaluates and stores each explicit entry in source order, so the
final store wins. The record-level visibility check (`cannot construct record
type ... because it has local fields`) rejects every `{...}` construction
outside the defining module when the record has any local field, before
omission can make private slots appear fillable.

This initializer path does not apply to union construction. A record payload is
one positional expression, as in `Message.move({ x = 1.0, y = 2.0 })`; the
parentheses distinguish the variant call from the brace-delimited named-call
syntax. A named union-variant call goes through `check_named_args` like any
other static.

## The Lua entry boundary is unchanged

`genluaentry` consumes Lua stack slots positionally, pads missing Lua arguments
under the ordinary Titan-function rule, ignores extras for a fixed function (or
collects them for an input-variadic one), and performs the usual boundary
checks. A Lua table carries no marker distinguishing a named bundle from an
intended table or `value`, so the entry inspects no keys. Declaration
`paramnames` exist only in Titan's compiled interface, not in the Lua wrapper
or a run-time map.

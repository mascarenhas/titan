# Lightweight named arguments

Status: implemented on `agent/lightweight-named-arguments`. This document is
retained as the design and validation record for the feature.

## 1. Outcome and evaluation

Add a named-only call form:

```lua
move { dx = 10, dy = 20 }
point:translate { dy = 20, dx = 10 }
Point.new { y = 3.0, x = 2.0 }
```

This first iteration is deliberately compile-time-only and narrow:

- accepted for direct calls to Titan top-level/module functions, record static
  functions, and record methods;
- accepted for direct, fixed-arity C FFI functions when the imported prototype
  supplies a complete, unambiguous list of parameter names;
- accepted for Titan declarations in the current module and for imported Titan
  declarations whose parameter names were recovered from module interface
  metadata;
- rejected for function values, anonymous functions, bound-method values, C
  function pointers, C pseudo-constructors, FFI functions without complete name
  metadata, and every Titan or C variadic function;
- never mixes positional and named arguments in one call;
- maps names to the existing Titan-native or direct-C positional calling
  convention, with no runtime name lookup and no generated function-ABI change;
- fills every omitted formal with `nil`, accepting the omission only when the
  formal's type accepts/coerces `nil` under Titan's existing rules;
- applies the same omitted-with-`nil` rule to named record-constructor fields.

The feature fits Titan well. Direct declarations already have parameter names,
the checker already synthesizes and checks missing `nil` arguments
(`titan-compiler/checker.lua:688-703,1880-2017`), Titan direct calls already end
in a positional native call (`titan-compiler/coder.lua:3138-3285`), and direct
FFI calls already have a distinct positional C lowering in `codeforeigncall`.
The substantial
cross-module addition is declaration metadata: the current structural function
types and serialized record method/static descriptors contain parameter types
but not parameter names (`titan-compiler/types.lua:3-35,997-1087`). The C parser
already captures simple parameter identifiers, but `c-parser/ctypes.lua` and
`titan-compiler/foreigntypes.lua` currently discard their availability while
building the Titan-visible callable descriptors.

The implementation should not put names into `Type.Function`. Function types are
structural, function values are explicitly outside named-call scope, and
parameter renaming must not change type equality, compatibility, first-class
function tags, or native signatures. Names belong to declaration/interface
descriptors instead.

## 2. Language decisions

### 2.1 Braces are the named-call delimiter

At a call suffix, every bare-brace form is named-argument syntax, including the
empty form:

```lua
f { x = 1 }
f{x = 1}
f {}
f{}
obj:m { x = 1 }
obj:m {}
obj:m{}
```

Parentheses remain positional syntax:

```lua
f(1, 2)
obj:m(1, 2)
```

This intentionally replaces Titan's current Lua constructor-argument sugar.
Today `f { x = 1 }`, `f { 1, 2 }`, and `f {}` all parse as a positional call
with one `Ast.ExpInitList` argument (`titan-compiler/parser.lua:717-755`; the
current expectations are in `spec/parser_spec.lua:1123-1153`). After this
feature, a constructor passed as one positional argument must be parenthesized:

```lua
consume_record({ x = 1 })
consume_array({ 1, 2 })
consume_map({ ["x"] = 1 })
consume_empty({})
```

The maintainer has confirmed this compatibility break: every old one-constructor
positional call must use parentheses. The all-braces rule gives each delimiter
one invariant meaning and makes the ban on mixing positional and named arguments
syntactic rather than heuristic. Bare-string call sugar (`f "text"`) can remain
a one-positional-argument form.

Whitespace is never required between the callee and `{`. `f{x = 1}`, `f{}`,
`mod.f{}`, and `obj:m{}` must parse exactly like their spaced equivalents. This
should follow from the existing suffix and `SKIP*` token primitives; do not add
whitespace lookbehind or a special adjacency rule.

Inside a named list, every item must be `Name = exp`. Computed keys, positional
items, `...`, and mixtures are syntax errors. Match existing constructor
punctuation by accepting comma or semicolon separators and an optional trailing
separator.

For this label position, `Name` means a raw identifier spelling, including a
Titan reserved word. C APIs can legitimately publish parameter names that are
Titan keywords; bundled libuv's `uv_timer_start` uses `repeat`. A dedicated
named-label lexer primitive should therefore accept `repeat = value` only in the
label-before-`=` position. The maintainer has confirmed this PEG-contextual rule.
It must not make keywords legal as Titan variable, field, or declaration names.

### 2.2 Empty calls and omitted parameters

`f {}` is an empty named call. Conceptually it maps every formal to a synthetic
`nil`. It succeeds only if all formals accept `nil`:

```lua
function defaults(x: integer?, enabled: boolean, payload: value)
end

defaults {} -- accepted: nil, false-through-coercion, nil
```

If any formal is not nil-compatible, report each required missing name (or one
deterministic error at a time if that is the checker's established convention).
Do not describe the call merely as having the wrong numeric arity: names are
available and give a better diagnostic.

The eligibility test must reuse the existing `nil_can_adjust_to` rule
(`checker.lua:688-691`; mirrored in `coder.lua:2669-2672`) so named calls agree
with positional optional-parameter behavior. Nil-capable cases include `T?`,
`value`, `boolean`, `nil`, and nullable pointer forms according to the existing
coercion/compatibility relations. Required scalar, string, container, record,
and function parameters remain errors when omitted.

### 2.3 Record constructors use the same omission rule

For a context-typed record constructor, an absent field is treated exactly like
an absent named formal:

```lua
record Config
    label: string?
    enabled: boolean
    payload: value
end

local a: Config = {}
local b: Config = { label = "test" }
```

Both examples are accepted because every omitted field can accept `nil`. A
missing non-nil-compatible field keeps the existing constructor error, enhanced
to explain that the field cannot be omitted because its type does not accept
`nil`.

The existing visibility wall remains unchanged: a record with any local field
cannot be constructed with `{...}` outside its declaring module, including `{}`
and even when every local field's type accepts `nil` (`checker.lua:2202-2221`).
This is a record-level constructibility check, not a per-field omission check.
Inside the declaring module, the constructor already has access to local fields,
so optional filling applies uniformly to both local and public fields.

### 2.4 Evaluation order

Evaluate the receiver once, then evaluate explicitly supplied named argument
expressions once each, left to right as written. Name-to-position mapping must
not reorder effects:

```lua
target {
    third = mark(1),
    first = mark(2),
    second = mark(3),
}
```

The calls to `mark` occur in the order `1, 2, 3`; the callee receives formal
values `(2, 3, 1)`. This preserves the current code generator's explicit
left-to-right call intent and behavior in `ordered_call_args`
(`coder.lua:1471-1524`); the new language chapter should establish it as part of
the named-call contract. Record-constructor expressions likewise continue to
evaluate explicit fields in source order (`coder.lua:4970-5028`). Synthetic nil
fills have no observable evaluation effect.

A call used as one named argument contributes only its first return value. Named
items are one-formal slots; the trailing-multi-return expansion used by
positional argument lists must not run for them.

### 2.5 Fixed-arity FFI functions

A direct function member of a `foreign import` supports named calls when all of
its effective fixed parameters have known, unique names and the C prototype is
not variadic:

```lua
local libuv = foreign import "uv.h"

libuv.uv_fs_open {
    loop = loop_handle,
    req = request_handle,
    path = path_data,
    flags = open_flags,
    mode = 438,
    cb = callback,
}
```

A true zero-parameter C prototype written `(void)` publishes an empty name list
and accepts `f{}`. Old-style C `f()` does not specify a parameter list in C99 and
therefore does not publish named-call metadata, even though the current FFI model
otherwise represents its parsed parameter array as empty. If any effective
parameter is unnamed, names are duplicated, or compatible redeclarations
publish conflicting complete name lists, named-call metadata is unavailable for
that function and named syntax gets a specific diagnostic. Positional calls
remain unchanged. C function-pointer values remain outside the feature even when
a typedef happened to spell parameter names: they are callable values, not
direct declaration members with a canonical source API.

Omitted FFI parameters use the same nil-adjustment rule after conversion to
Titan's C types. Thus a nullable pointer can be omitted and becomes `NULL`, while
a required C integer cannot. C variadic functions reject named syntax entirely,
even when every fixed-prefix name is present.

### 2.6 Names are source API, not function type identity

For exported declarations, parameter names become part of the source-facing API:
renaming a parameter can break recompilation of a named caller. It does not
change binary calling convention or structural function compatibility. Existing
compiled callers have already lowered names to positions and continue to call
the same native symbol positionally.

For C FFI declarations, header parameter spellings likewise become source API
for named callers, but never C type identity or ABI. Compatible redeclarations
continue to compare by types, not parameter spelling. Because system-header
spellings can drift independently of ABI, production dogfooding must compile
against both Titan's pinned bundled headers and supported system libuv headers.

The implicit method receiver `self` is never a named formal. A method's published
name list contains only its explicitly declared parameters, in declaration
order. A variadic marker has no name and is excluded from the fixed name list.

### 2.7 Lua calls remain positional-only

Do not change `genluaentry` or reinterpret a Lua table as named arguments. In
Lua, `mod.f { x = 1 }` is exactly `mod.f({ x = 1 })`; the call carries no syntax
marker that distinguishes a named bundle from an intended table/value argument.
Inspection by arity, key shape, or formal type remains ambiguous for `value`,
table-like parameters, and nil-compatible tails, and would make behavior depend
on runtime contents.

The only clean future Lua design would be explicit opt-in, such as a tagged
`titan.named { ... }` wrapper or a separately named generated entry point. That
would require runtime tagging, generated name maps, API design, and new boundary
tests, so it is outside this lightweight iteration. A Lua table passed to a
one-`value` Titan function must continue to arrive as that one ordinary value.

## 3. Current implementation seams

- `ast.lua:83-86` has only positional `ArgsFunc` and `ArgsMethod` nodes.
- `parser.lua:279-301` builds function/method suffix closures, and
  `parser.lua:717-755` sends parenthesized lists, constructors, and strings
  through the same `funcargs` path.
- `parser.lua:774-790` already has the field-list punctuation and `Field`
  representation, but named-call grammar should accept only identifier keys.
- `lexer.lua:168-196` deliberately excludes Titan keywords from `NAME`; named
  labels need a narrower raw-identifier primitive because C parameters such as
  libuv's `repeat` are valid labels but invalid Titan variable names.
- `checker.lua:2605-2757` resolves all call forms. Function calls and method calls
  share `checkargs` after different declaration lookup paths.
- Direct function provenance is already represented by `Ast.TopLevelFunc`,
  `Type.ModuleMember`, and `Type.StaticMethod`; direct methods carry a resolved
  `Type.Method` on `ExpCall._method` (`checker.lua:1729-1769,2605-2757`).
- `coder.lua:2643-2659` has the authoritative direct-callee classification used
  to choose `codecall` rather than `codevaluecall`.
- `coder.lua:3138-3285` evaluates the method receiver, evaluates positional
  arguments, and emits the native positional call.
- `c-parser/c99.lua:431-450` captures C parameter declarators, and
  `c-parser/ctypes.lua:144-217,519-611` currently retains each simple parameter's
  `.name` but does not publish a complete name-list availability result.
- `foreigntypes.convert_function` (`foreigntypes.lua:322-327`) exposes a direct
  FFI function as structural `Type.Function`, and the foreign-import checker
  currently wraps it in `Type.ModuleMember` without copying the raw CType's name
  metadata (`checker.lua:3297-3349`). `Type.CFunction` remains the structural
  signature used inside excluded pointer/callback types.
- `coder.codeforeigncall` (`coder.lua:2576-2597`) has a separate direct-C lowering
  path and currently traverses dense arguments in formal order; named FFI calls
  need the same lexical-evaluation/formal-emission split as native calls.
- `types.lua:13-22` separates structural `Function` from declaration-like
  `ModuleMember`, `Method`, and `StaticMethod` descriptors.
- `checker.lua:3384-3523` builds function/method/static signatures;
  `checker.lua:3730-3748` builds the exported `Type.Module` interface.
- `types.lua:997-1087`, `coder.lua:7373-7377,8103-8106`, and
  `driver.lua:250-274` are the serialize/export/rehydrate path for `.so`
  interfaces. `driver.tableloader` also forces the same round trip for source
  imports (`driver.lua:397-428`).
- `checker.lua:2187-2262` checks record constructor fields and currently reports
  every absent field as an error.
- `titan/uv.titan` contains long direct FFI calls, long local Titan calls, and
  large record static calls; `titan/{async,timer,fs,net,os}.titan` consume its
  exported surface through the compiled `titan/uv.so`, making them a production
  integration proof for both metadata paths.
- The compiled module ABI and installation namespace are currently 0.12 in
  `driver.lua:15-16`, `titan-runtime/titan.h:59-65`, and `Makefile:207-210`.

## 4. Implementation plan

Execution prerequisite: use a dedicated absolute prefix throughout the
implementation so the 0.13 compiler, Lua default C path, SDK, and standard
library cannot be confused with an existing 0.12 installation. The ABI version
participates in Lua's build configuration stamp (`Makefile:282-330`), so rerun
`make lua`; installing only the new rock would leave a warm Lua binary searching
the old versioned path. Reinstall the rock after each compiler edit batch because
Busted resolves the installed snapshot before working-tree Lua sources:

```sh
export PREFIX="/tmp/titan-$USER-named-arguments"
export PATH="$PREFIX/bin:$PATH"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
CCACHE_DISABLE=1 make lua
CCACHE_DISABLE=1 make luarocks
CCACHE_DISABLE=1 make libuv
CCACHE_DISABLE=1 "$PREFIX/bin/luarocks" make
```

### Phase A: parser and AST

1. Extend the `Args` group in `titan-compiler/ast.lua` with distinct named forms,
   for example:

   ```lua
   ArgsNamedFunc   = {"loc", "fields"}
   ArgsNamedMethod = {"loc", "method", "fields"}
   ```

   Reuse `Ast.Field` for each `name = exp` item. Here `field.name` is always a
   string; positional/AST-key variants are not legal in these nodes.

2. Split parser call suffixes into positional and named paths.

   - Keep `(...)` and a bare string in ordinary `funcargs`.
   - Remove bare `constructor` from ordinary positional `funcargs`.
   - Add `namedargs <- '{' [namedarglist] '}'`, with
     `namedarg <- NamedLabel '=' exp`.
   - Add a lexer/parser primitive for `NamedLabel` that captures the raw C/Titan
     identifier spelling even when it is a Titan keyword, but only in this
     label-before-`=` production. Keep ordinary `NAME` unchanged.
   - Add separate suffix actions for function and method named calls so the AST
     retains the delimiter choice.
   - Keep comma/semicolon separators and trailing separators.
   - Ensure an empty list produces `ArgsNamedFunc/Method` with zero fields.
   - Rely on the existing suffix/token skip machinery for both `f {}` and `f{}`;
     add no whitespace requirement or adjacency state.

3. Add named-list-specific labels to `syntax_errors.lua` for a missing name,
   `=`, expression, and closing brace. A positional/computed entry such as
   `f { 1 }` or `f { [k] = v }` should say that a named argument was expected,
   not fall through to a generic expression error. A mixed list should fail at
   the first non-named item.

4. Update the parser's call-suffix comments and `defs.*` helpers. Preserve the
   existing closure-based suffix folding and chaining (`f {x=1}.field`, where
   otherwise type-correct).

5. Update `spec/parser_spec.lua` before checker work so the new parse contract is
   fixed:

   - spaced and adjacent forms (`f {x = 1}`/`f{x = 1}`, `f {}`/`f{}`,
     `m.f{}`, and `o:m {}`/`o:m{}`) produce the same appropriate named Args
     nodes;
   - reordered/nonempty function and method lists retain name/expression order;
   - a reserved-word label such as `f{ repeat = 1 }` is captured as the string
     `"repeat"`, while `repeat` remains illegal in ordinary name positions;
   - `f({})`, `f({x = 1})`, `f({1, 2})`, and `f({[k] = v})` remain one positional
     `ExpInitList` argument;
   - bare positional, computed-key, `...`, and mixed brace lists fail cleanly;
   - missing value, separator tail, and missing `}` use stable labels;
   - ordinary parenthesized and bare-string calls are unchanged.

### Phase B: declaration metadata and serialization

1. Add parameter-name metadata to the declaration/interface descriptors in
   `types.lua`:

   - append `paramnames` to `Type.ModuleMember`;
   - append `paramnames` to `Type.Method`;
   - append `paramnames` to `Type.StaticMethod`.

   Use `false` when a module member is not a callable declaration or when its
   complete names are unavailable, and a dense array of strings when they are
   known. Preserve an empty array for a true zero-parameter Titan or C callable;
   it is distinct from `false`.

2. Leave both `Type.Function` and `Type.CFunction` unchanged. Do not incorporate
   names from `Type.ModuleMember` in `types.equals`, `types.compatible`,
   `types.tostring`, C declarator rendering, function-type registry keys/tags,
   `function_sig`, or `codevaluecall`. Names belong to direct declarations, not
   structural Titan/C function types or callable pointer values.

3. Refactor `checker.lua:param_types` to return fixed parameter names alongside
   fixed types and `varargtype`, excluding the trailing `name == false` variadic
   marker. Use the result when constructing `Type.Method` and
   `Type.StaticMethod` in the signature pass.

4. When `makemoduletype` wraps an exported top-level function in
   `Type.ModuleMember`, publish its fixed parameter-name list. Records get
   `paramnames=false`. Local same-module top-level calls can read names directly
   from `Ast.TopLevelFunc.params`; local record members already have their
   `Type.Method/StaticMethod` descriptors.

5. Extend the C declaration pipeline without changing C type compatibility.

   - Keep `c99.lua:parameterDeclaration`'s declarator/name capture as the parser
     source of truth.
   - Preserve whether the declarator used a prototype parameter-type list. The
     parser/type layer must distinguish old-style `f()` (arity/names unavailable
     for this feature) from `f(void)` (known empty list), even though both
     currently collapse to an empty `params` array.
   - Change `ctypes.get_params` to return `params`, `vararg`, and name
     availability. Exclude the `(void)` sentinel and `...`; return `{}` for a
     true `(void)` prototype and unavailable when the form is old-style, any
     effective parameter is unnamed, or names are duplicated.
   - Store that availability result on intermediate CType `function` and
     `functionptr` descriptors. Cover ordinary prototypes, parenthesized names,
     static/inline definitions, arrays, callbacks, and abstract declarators.
   - Keep `equal_declarations` name-insensitive. Maintain a separate tri-state
     name accumulator across compatible declarations: `unknown` (no complete
     list seen and still upgradable), one complete agreed list, or permanently
     `conflicting`. A complete list upgrades `unknown`; an identical list keeps
     consensus; a different complete list poisons the state; and no later
     declaration can recover from `conflicting`. Do not let a later unnamed
     prototype erase good metadata or declaration order choose an arbitrary API.
     Normalize both `unknown` and `conflicting` to
     `Type.ModuleMember.paramnames=false` at the Titan boundary.

6. When the checker wraps a direct converted C function as `Type.ModuleMember`,
   copy the finalized raw CType function descriptor's complete `paramnames` onto
   that declaration wrapper even though its exposed call type remains structural
   `Type.Function`. Non-function C members and unavailable/conflicting name
   states use `false`. Do not propagate declaration labels into
   `Type.CFunction`; that type represents function-pointer/callback signatures,
   which remain outside named-call eligibility.

7. Update every `Type.ModuleMember`, `Type.Method`, and `Type.StaticMethod`
   constructor call (including foreign conversion and unit-test fixtures) for
   the new arity. Do not use ad-hoc underscore decorations that would be lost in
   `types.serialize`.

8. Extend `types.serialize` so the name lists round-trip in:

   - top-level callable `ModuleMember` entries;
   - public record `Method` entries;
   - public record `StaticMethod` entries, including synthesized public `new`.

   Render names with Lua string quoting (`string.format("%q", name)`) and a
   deterministic array order. Local declarations/members remain omitted by the
   existing public-interface filter. `Type.CModule`/`Type.CFunction` remain
   non-serializable and are rebuilt from headers; the FFI work does not add a
   second `.so` metadata format or require another ABI bump beyond 0.13.

9. Add metadata-layer coverage proving:

   - `spec/types_spec.lua`: declaration metadata round-trips through
     `serialize`/`load`;
   - zero-parameter declarations preserve `{}` rather than “unavailable”;
   - parameter names do not affect structural `Type.Function` equality or tags;
   - method/static names survive record serialization;
   - `spec/ctypes_spec.lua`: named, unnamed, partially named, old-style `()`,
     prototype `(void)`, variadic, array/function-pointer,
     static/parenthesized, keyword-spelled, and agreed/conflicting C declarations
     preserve the expected complete/unavailable state;
   - three-or-more compatible redeclaration permutations prove a poisoned name
     conflict can never be re-enabled by a later matching list;
   - `spec/foreigntypes_spec.lua` and `spec/types_spec.lua` prove structural
     `Type.Function`/`Type.CFunction` conversion, equality, compatibility, and
     rendering remain independent of declaration names;
   - `spec/checker/c_ffi_spec.lua` inspects the resulting direct foreign
     `Type.ModuleMember.paramnames` for complete, empty, and unavailable cases.

### Phase C: checker eligibility and named-to-positional elaboration

1. Refactor the start of `checkexp[Ast.ExpCall]` to classify all four argument
   tags explicitly: positional/named function calls and positional/named method
   calls. Replace the current `ArgsFunc`/`else assert ArgsMethod` split. Add a
   shared `check_call_argument_expressions` recovery helper that visits
   `arg`/`field.exp` as appropriate. Use it on every early callee-resolution,
   visibility, unsupported-target, and missing-method error path so invalid
   named calls still report nested expression errors without indexing
   `node.args.args` when the payload is actually `node.args.fields`.

   Audit `checker.isconst` too (`checker.lua:3162-3202`). Top-level initializer
   checking can call it after `checkexp` has already rejected a call, and its
   constructor-call branches currently iterate `node.args.args` directly. It
   must use the same tag-aware accessor/recovery convention so a rejected named
   pseudo-constructor or malformed named `Rec.new` cannot crash the checker.

2. Add one helper that extracts named-call metadata from a resolved direct
   declaration and classifies the lowering as Titan-native or direct C FFI. Its
   accepted provenance is:

   - `Ast.TopLevelFunc` in the current module;
   - a Titan-module `Type.ModuleMember` whose `type` is `Type.Function` and whose
     `paramnames` are available (not `false`);
   - `Type.StaticMethod`;
   - the resolved `Type.Method` on a method call;
   - a direct member of `Type.CModule` whose declaration is a C function,
     whose exposed call type is `Type.Function`, and whose
     `Type.ModuleMember.paramnames` are available.

   Explicitly reject C function-pointer calls, `Type.CPseudoNew`, arbitrary
   `Type.Function` values, `ExpFunction`, and bound method values. A direct C
   function with `paramnames=false` is a recognized-but-unavailable target and
   gets a specific name-metadata diagnostic rather than the generic unsupported
   callable error. Do not infer eligibility merely because a callee's static
   type is `Type.Function`.

3. Reject a named call before elaboration if either `ftype.varargtype` (Titan
   variadic) or `ftype.vararg` (foreign C variadic) is present. The diagnostic
   should name the declaration and say named arguments are unavailable for
   variadic functions; do not silently name only the fixed prefix.

4. Implement `check_named_args`, taking the formal types, formal names, source
   `Field` list, and a call description. It should:

   - build a name-to-formal-index map and assert metadata length matches fixed
     arity;
   - visit supplied fields left-to-right;
   - reject an unknown name with the callee and available formal names;
   - reject a duplicate supplied name at its second occurrence;
   - check each valid expression in the corresponding formal's type context,
     apply `trycoerce`, and use `checkmatch` with a name-specific diagnostic;
   - treat each supplied field as exactly one value, even when its expression is
     a multi-return call;
   - for every absent formal, synthesize `Ast.ExpNil`, then coerce/check it when
     `nil_can_adjust_to(formal)` succeeds;
   - report a named missing-argument diagnostic when it does not, avoiding a
     duplicate generic type-mismatch report;
   - still check expressions attached to unknown/duplicate fields far enough to
     collect ordinary nested errors, while ensuring failed calls never reach
     code generation.

   Use this omission rule for eligible direct FFI calls too; do not pass them
   through positional `checkargs(..., allow_missing=false)`. Keep ordinary
   parenthesized FFI calls strict so this feature does not silently alter their
   existing arity contract.

5. Produce a dense positional argument array indexed by formal position. Replace
   `ArgsNamedFunc` with `ArgsFunc`, or `ArgsNamedMethod` with `ArgsMethod`, before
   codegen. Skip ordinary `checkargs` for that call: the named helper has already
   completed arity/type work, and `checkargs`'s trailing multi-return expansion
   would be wrong for a named item.

6. Decorate the checked `ExpCall` with a source-evaluation mapping, for example
   `_named_arg_order = { formal_index_1, formal_index_2, ... }`, containing only
   explicitly written fields in lexical order. The dense args array contains the
   synthetic omissions too. Document this decoration in
   `doc/implementation/ast-typedecl.md`.

7. Keep all existing result typing (`_types`, first result/`Void`, `_method`),
   direct-FFI provenance, and visibility checks unchanged. The named path joins
   the appropriate native or foreign call path only after callee resolution and
   eligibility validation.

8. Add `spec/checker/named_arguments_spec.lua` with focused cases for:

   - same-module local and exported top-level functions;
   - source-imported functions (which already pass through
     `driver.tableloader` serialization);
   - record statics, synthesized `Rec.new`, and record methods, including option
     receivers and effectful/chained receiver expressions;
   - arbitrary name order and type coercion by the selected formal;
   - `f {}` and partial calls with all omissions nil-compatible;
   - a true zero-parameter `f {}` and a true zero-field `Empty.new {}`;
   - required missing names, unknown names, duplicates, and type mismatch;
   - calls returning multiple values used as a single named item;
   - a reordered direct FFI call, a keyword label such as `repeat`, and a true
     zero-parameter `(void)` FFI `f{}`;
   - omitted nullable C pointer acceptance and missing C scalar rejection;
   - distinct rejection of old-style `f()`, unnamed/partially named prototypes,
     and permanently conflicting redeclaration metadata, plus unknown and
     duplicate FFI names;
   - rejection of first-class function variables, lambdas, bound methods, C
     function pointers/pseudo-constructors, and optional function values;
   - rejection of Titan and C variadic declarations even when only fixed names
     are supplied;
   - unchanged strict arity for positional FFI calls.

### Phase D: code generation and evaluation order

1. Keep generated Titan signatures, C prototypes, and Lua entries unchanged.
   After checker normalization, Titan named calls reach `codecall` and direct
   FFI named calls reach `codeforeigncall`, both as dense positional calls plus
   the lexical formal-index mapping.

2. Keep the dense positional normalization and make its codegen invariant
   precise. Add a named-specific sibling of `ordered_call_args` for Titan-native
   arguments; it must not traverse or call `codeexp` on the dense argument array
   before applying the mapping.

   - Allocate a formal-indexed `actuals` array and an empty mapped-index set.
   - Iterate `_named_arg_order` in lexical order. For each formal index, fetch
     exactly `node.args.args[formal_index]`, generate it once, materialize it
     immediately into a typed temporary, store the resulting C expression in
     `actuals[formal_index]`, and mark the index mapped.
   - Iterate formal indexes only after all explicit fields have been
     materialized. Every unmapped dense argument is, by checker invariant, a
     synthetic nil fill; generate it into its formal slot without revisiting a
     supplied expression.
   - Retain the existing GC stack-slot anchoring from `materialize_code` for
     strings, records, tables, function values, and options.
   - Assemble the native C operand list strictly as
     `actuals[1], ..., actuals[n]`.

   Assert that mapped indexes are unique/in range and that their complement is
   exactly the checker-created omissions. This separates lexical evaluation
   order from formal call order without relying on C argument evaluation order.

3. In method calls, retain the current order: materialize/unwrap the receiver
   once (`coder.lua:3188-3212`) before evaluating named fields. Do not reevaluate
   the receiver during metadata lookup or reordering.

4. Teach `codeforeigncall` the corresponding mapping rather than routing C calls
   through Titan materialization:

   - visit explicit fields in `_named_arg_order` and call `codeforeignexp` with
     the selected formal C type in lexical order;
   - store each converted expression and any `mutable_out_anchor`/post-call
     copyback by formal index;
   - generate only the synthetic omissions afterward;
   - emit the final C operand list and post-call actions in formal order.

   This preserves pointer/array/callback conversions and mutable-address copyback
   while preventing the formal reordering from changing source effects.

5. Add defensive assertions that `_named_arg_order` appears only on a resolved
   direct non-variadic Titan or C declaration and that the chosen lowering agrees
   with that provenance. It must never enter `codevaluecall`,
   `codecfunctionptrcall`, a C pseudo-constructor path, or vararg emission.

6. Add `spec/coder/named_arguments_spec.lua` runtime proofs for:

   - correct name-to-position mapping on functions, statics, methods, and
     `Rec.new`;
   - an effectful reordered call that distinguishes lexical evaluation order
     from formal order;
   - a method receiver with a side effect, proving it runs once before fields;
   - an option receiver and a chained/effectful receiver, proving existing
     unwrap/resolution semantics survive the new Args-tag branch;
   - nested calls and GC-bearing string/record/function values under reordered
     names, with collection pressure where practical;
   - empty and partial named calls applying nil/false/value behavior;
   - true zero-parameter and zero-field empty calls, including source-imported
     declarations where applicable;
   - multi-return expressions contributing one named value;
   - static C helpers proving FFI lexical evaluation versus formal mapping,
     conversions, omitted pointer-to-`NULL`, zero-argument `(void)` `f{}`, and
     mutable address/copyback behavior;
   - no behavior change at the Lua entry: a Lua table passed to one `value`
     parameter remains the same table value, and Lua cannot request named
     mapping.

### Phase E: optional fields in record constructor expressions

1. Refactor the nominal `ExpInitList` arm in `checker.lua:2187-2262`, preserving
   the existing record-wide constructibility check before omission analysis. If
   the record has any local field and the construction occurs outside the
   declaring module, reject the whole constructor—including `{}`—before
   synthesizing anything. Then build a supplied-field map while preserving the
   explicit field list's source order.

2. Preserve existing duplicate-field behavior. Record constructor expressions
   currently evaluate/store duplicate fields in source order, with the last
   store winning; the supplied-field map is only for deciding whether a formal
   field is absent and must not deduplicate or reorder the explicit list. Named
   call arguments still reject duplicates independently.

3. For each record field not supplied:

   - if `nil_can_adjust_to(field.type)`, synthesize a named `Ast.Field` containing
     a coerced `Ast.ExpNil`, attach the resolved `Type.Field` as `_field`, and
     append it after explicit fields;
   - otherwise emit the required-field error.

   Inside the declaring module, this iteration includes local fields as well as
   public fields. Outside it, only records with no local fields have survived the
   constructibility check, so all their fields participate normally. Appending
   synthetic nil fields preserves source order for all explicit expressions.
   `coderecord` can then use its existing field store path without a special
   missing-slot case, even though new userdata starts nil-filled.

4. Preserve all existing rules for unknown/positional fields, type coercion,
   local record/local field visibility, nominal context, and nested constructor
   context.

5. Add checker and coder cases (in the named-argument topical specs, or a small
   record-constructor subsection in the existing record specs) for:

   - `local r: R = {}` when every field accepts nil;
   - a partial constructor omitting option/value/boolean/nullable fields;
   - an empty/partial constructor rejected for each required field;
   - nested optional record constructors;
   - duplicate supplied record fields retaining their existing source-order,
     last-store-wins behavior;
   - generated values read back with the expected nil/false semantics;
   - a record with nil-compatible local fields accepting `{}` and partial
     construction inside its declaring module;
   - the same record rejecting every constructor form, especially `{}`, from an
     importing module regardless of the local fields' nil compatibility, while
     its synthesized `Rec.new` remains local/inaccessible as today;
   - imported records with no local fields continuing to use the ordinary
     omission rule.

### Phase F: `.so` metadata, ABI 0.13, and installation paths

The serialized interface constructor shapes change, so advance the compiled
module ABI from 0.12 to 0.13. A separate optional metadata symbol would avoid a
version bump but would create a second interface channel and provenance rules;
that is needless indirection when `<mangled>_types` is already the canonical
declaration interface.

1. Set `driver.TITAN_VER = "0.13"` and suffix `_0_13`.

2. Set `TITAN_VER`/`TITAN_VER_SUFFIX` in `titan-runtime/titan.h` and add a
   `0.12 -> 0.13` history note: native call frames are unchanged, but compiled
   interface metadata now publishes formal names and older type-constructor
   environments cannot interpret the new descriptor shape safely.

3. Set `TITAN_ABI_VERSION := 0.13` in the Makefile so canonical standard-library
   DSOs move to `lib/titan/0.13` and `TITAN_PATH_0_13` becomes the versioned
   override.

4. Update current-version/path references and exact expectations in:

   - `AGENTS.md` and `README.md`;
   - `spec/abi_spec.lua`, `spec/driver_spec.lua`, `spec/rockspec_spec.lua`,
     `spec/stdlib/coroutine_spec.lua`, `spec/stdlib/uv_states_spec.lua`, and
     `spec/support/{async_stdlib.lua,ci_libuv_mode_smoke.sh}`;
   - the current-path/current-version portions of the language and implementation
     manuals found by `rg '0\.12|0_12|TITAN_PATH_0_12'`.

   Preserve historical prose explaining the older 0.11 -> 0.12 type-alias bump;
   add the new transition rather than blindly replacing every historical
   occurrence.

5. Extend `spec/checker/so_rehydration_spec.lua` with a dependency available only
   as a `.so`. Prove named calls to an exported function, record static, and
   method type-check using recovered names; include a zero-parameter exported
   function and a zero-field exported record called with `{}`; prove an unknown
   name fails. Inspect recovered descriptors directly where useful.

6. Extend `spec/coder/so_import_spec.lua` with an end-to-end binary-only chain
   that executes named calls across the DSO boundary. This proves both interface
   recovery and unchanged positional native linkage.

7. Keep the existing ABI-marker-before-types ordering in
   `driver.load_compiled_interface` (`driver.lua:250-274`). A 0.12 DSO must fail
   with the normal ABI mismatch before its old metadata is evaluated.

8. Extend `spec/abi_spec.lua` with a fake module whose ABI entry explicitly
   returns `0.12`, and assert the clean `expected 0.13 but found 0.12` diagnostic.
   Keep the existing markerless-module case too; the two failures prove distinct
   loader contracts.

### Phase G: documentation

Treat this as a user-visible language feature and add both manuals in the same
change.

1. Add `doc/language/named-arguments.md`, covering:

   - braces vs. parentheses and the migration from constructor call sugar;
   - whitespace-insensitive `f{}`/`f {}` spellings and keyword labels in the
     named-list position;
   - eligible direct Titan and fixed-arity FFI declarations and all excluded
     callable forms;
   - no positional/named mixing and no variadic calls;
   - name matching, duplicates, unknowns, coercion, source evaluation order, and
     one-value-per-name behavior;
   - empty/partial calls and nil-compatible omission;
   - the identical record-constructor omission rule and the absolute
     outside-module construction ban for records with local fields;
   - exported Titan and C-header parameter names as source API;
   - Lua's positional-only boundary and the reason no inference is attempted.

2. Add `doc/implementation/named-arguments.md`, covering:

   - `ArgsNamed*` parse nodes and checker normalization;
   - declaration-only `paramnames` metadata, C parser/type preservation, and why
     `Type.Function` remains unchanged;
   - serialization/rehydration and the 0.13 ABI bump;
   - `_named_arg_order`, source-order materialization, GC anchoring, and the
     parallel native/foreign direct-call paths;
   - record missing-field synthesis;
   - why `genluaentry` is untouched.

3. Link both chapters from `doc/language/index.md` and
   `doc/implementation/index.md`.

4. Update the existing cross-cutting chapters:

   - `doc/language/functions.md` for call forms and optional named arguments;
   - `doc/language/records.md` for `Rec.new { ... }`, partial/empty constructors,
     and optional fields;
   - `doc/language/expressions.md` to replace constructor call sugar and fix its
     stale strict-arity wording at `expressions.md:471-490`;
   - `doc/language/grammar.md` for named Args and parenthesized constructor
     arguments;
   - `doc/language/lua-interop.md` for positional-only Lua calls;
   - `doc/language/ffi.md` for named direct C functions, unavailable prototype
     names, keyword labels, and the continuing function-pointer exclusion;
   - `doc/implementation/{lexer-parser,ast-typedecl,checker,codegen-overview}.md`
     for the new seams and links to the focused chapter;
   - `doc/implementation/ffi-internals.md` for the
     `c99 -> ctypes -> foreigntypes -> ModuleMember` name pipeline and
     `codeforeigncall` lowering;
   - `doc/implementation/driver.md` and current ABI/path documentation for 0.13.

5. Update roadmap/status wording if named arguments are listed as unsupported.
   Search first; do not invent a roadmap entry if none exists.

### Phase H: delegated `uv` standard-library dogfood migration

Treat production adoption as part of the test plan, not as optional cleanup.
Start this phase only after the parser, FFI metadata, checker, codegen, ABI, and
focused named-argument specs are green under the current installed compiler.

1. The main agent must delegate this bounded refactor to a subagent. Give that
   subagent exclusive edit scope over:

   - `titan/uv.titan`;
   - `titan/{async,timer,fs,net,os}.titan`;
   - `spec/support/make_delayed_fs_callback_variant.lua` only if an exact textual
     anchor must be updated.

   The subagent must not edit compiler/runtime implementation files. If the
   migration exposes a compiler defect, it should report a minimal source case
   and stop that portion; the main agent owns the compiler fix and focused
   regression before resuming the delegated refactor. Do not concurrently edit
   the delegated files.

2. In `titan/uv.titan`, convert representative long direct FFI call clusters to
   named form using the exact names parsed from the authoritative headers, not
   friendlier aliases:

   - filesystem submissions around `uv.titan:2260-2293`, especially
     `uv_fs_open` (six parameters) and `uv_fs_read`/`uv_fs_write` (seven);
   - process setup/spawn around `uv.titan:3106-3125`, especially
     `titan_uvshim_process_spawn` (seven);
   - DNS/TCP submissions around `uv.titan:3547-3689`, including
     `getaddrinfo_start` and `tcp_connect_start` (five each);
   - `titan_uvshim_stat_extract` around `uv.titan:3915-3917` (six);
   - at least one function whose C parameter is a Titan keyword, such as
     `uv_timer_start { repeat = ... }`.

   The initial header truth surfaces are
   `libuv-v1.52.1/include/uv.h:977-980,1470-1497` and
   `titan-runtime/titan/uv.h:120-186,224-226`. The compiler must still parse the
   active header rather than hard-coding these names. Leave calls such as
   bundled libuv's `uv_timer_init` and `uv_read_start` positional when their
   active prototypes omit a parameter name; do not invent aliases merely to
   maximize conversion count. Their coexistence with named calls is a useful
   production proof of the availability boundary.

3. Convert every call site of a bounded set of long local Titan functions so the
   production source exercises name mapping rather than merely containing one
   showcase call:

   - `start_owner` (seven parameters; declaration near `uv.titan:2301`);
   - `make_fs_operation` (eight; near `uv.titan:2732`);
   - `new_net_request` (seven; near `uv.titan:2796`);
   - `make_process_operation` (seven; near `uv.titan:2817`);
   - `schedule_task_drive` (six; near `uv.titan:3418`).

   Preserve each old operand's lexical evaluation order in the rewritten named
   list. Use a different order only in focused compiler fixtures designed to
   prove reordering semantics.

4. Convert the largest record statics/constructors, including
   `FsConstants.new` (16 fields), `uv_file.new` (13), `TimerControl.new` (8),
   `Request.new` (6), `FsOperation.new` (16), and `HelperGroup.new` (17).
   Omit explicit `nil` fields where the new omission rule permits it, but retain
   required boolean/scalar values. Private control records such as `uv_file` and
   `FsOperation` are deliberate proofs that local fields are fillable inside the
   declaring module; do not add any outside-module construction of them.

5. In all five immediate facade consumers—`async.titan`, `timer.titan`,
   `fs.titan`, `net.titan`, and `os.titan`—convert their direct `uv._*` calls to
   named form. This finite boundary is currently about 60 calls and exercises
   formal names rehydrated from the already-built `titan/uv.so`. Strong
   multi-parameter cases include `_net_listen`/`_bytes_slice` in `net.titan`,
   `_os_process_read_error_is`/`_bytes_slice`/`_os_communicate` in `os.titan`, and
   the filesystem bridge calls in `fs.titan`.

6. Include two intentional no-space sentinels:

   ```lua
   uv._loop{}
   libuv.uv_version_string{}
   ```

   The first proves zero-parameter named calls through compiled Titan module
   metadata. The second proves both a zero-parameter direct FFI call and the
   whitespace-free spelling.

7. Review `spec/support/make_delayed_fs_callback_variant.lua` for textual anchors
   into `uv.titan`, then run `spec/stdlib/uv_late_fs_callbacks_spec.lua` even if
   no anchor edit appears necessary. The source-transform fixture must fail
   loudly rather than silently stop injecting its delayed callbacks. During the
   delegated iteration, use the focused gates for quick fault localization:

   ```sh
   CCACHE_DISABLE=1 make stdlib
   CCACHE_DISABLE=1 busted spec/stdlib/uv_late_fs_callbacks_spec.lua
   CCACHE_DISABLE=1 bash spec/support/ci_test_groups.sh library-uv-fs
   CCACHE_DISABLE=1 bash spec/support/ci_test_groups.sh library-net-os
   ```

8. After the subagent reports green focused results and the main agent reviews
   the diff, run the complete library group once, build the process-smoke child
   required by the mode script, and exercise the production images:

   ```sh
   CCACHE_DISABLE=1 bash spec/support/ci_test_groups.sh libraries
   process_smoke_dir="${TMPDIR:-/tmp}/titan-named-args-process-smoke"
   mkdir -p "$process_smoke_dir"
   TITAN_PROCESS_SMOKE_DIR="$process_smoke_dir" \
     "$PREFIX/bin/lua" -e 'require("spec.support.os_test_support").process_child(assert(os.getenv("TITAN_PROCESS_SMOKE_DIR")))'
   TITAN_PROCESS_SMOKE_CHILD="$process_smoke_dir/process_child" \
     CCACHE_DISABLE=1 bash spec/support/ci_libuv_mode_smoke.sh
   ```

   `make stdlib` is a particularly strong proof: it compiles `uv.titan` from
   source against the C headers, then builds the five facades binary-first
   against `uv.so` (`Makefile:874-967`). The mode smoke recompiles the provider
   against both bundled and system libuv where available, catching header-name
   drift as well as runtime regressions. A local host without system-libuv
   prerequisites may pass `bundled`, but the published Linux/macOS validation
   must run the full two-mode smoke.

### Phase I: repository migration and final validation

1. Search Titan sources, embedded Titan fixtures, examples, and docs for the old
   bare-constructor call sugar. Convert intended positional constructor calls to
   parentheses. Do not mechanically parenthesize record constructor expressions
   that are not call suffixes.

2. Run focused gates from the repository root:

   ```sh
   CCACHE_DISABLE=1 busted spec/parser_spec.lua
   CCACHE_DISABLE=1 busted spec/ctypes_spec.lua spec/foreigntypes_spec.lua spec/types_spec.lua
   CCACHE_DISABLE=1 busted spec/checker/c_ffi_spec.lua spec/coder/c_ffi_spec.lua
   CCACHE_DISABLE=1 busted spec/checker/named_arguments_spec.lua
   CCACHE_DISABLE=1 busted spec/coder/named_arguments_spec.lua
   CCACHE_DISABLE=1 busted spec/checker/so_rehydration_spec.lua
   CCACHE_DISABLE=1 busted spec/coder/so_import_spec.lua
   CCACHE_DISABLE=1 busted spec/abi_spec.lua spec/driver_spec.lua spec/rockspec_spec.lua
   ```

3. Inspect generated C from both Titan-native and direct-FFI reordered/effectful
   fixtures. Confirm explicit expressions/conversions are emitted in lexical
   order, each native/C argument list is in formal order, foreign post-call
   anchors are retained, and no runtime name table or Lua-stack generic call was
   introduced.

4. Run the authoritative full suite and hygiene checks:

   ```sh
   CCACHE_DISABLE=1 make test
   git diff --check
   ```

5. If the implementation is later published, let the branch push exercise the
   Linux workflow and manually dispatch the complete macOS pre-merge gate:

   ```sh
   gh workflow run ci.yml --ref <branch>
   ```

## 5. Diagnostic contract

Exact wording can follow the surrounding checker voice, but focused specs should
stabilize these distinctions:

- syntax: `expected a named argument of the form 'name = expression'`;
- unsupported target: named arguments require a direct Titan module function,
  record function, method, or fixed-arity FFI function;
- unavailable FFI names: parameter names are unavailable for foreign function
  `<name>` because its prototypes do not provide one complete unambiguous list;
- variadic target: named arguments are not supported for variadic Titan or C
  function `<name>`;
- unknown: function/method `<name>` has no parameter named `<arg>`;
- duplicate: named argument `<arg>` is supplied more than once;
- missing: parameter `<arg>` of type `<type>` cannot be omitted because it does
  not accept nil;
- mismatch: types in named argument `<arg>` do not match, expected `<type>` but
  found `<type>`;
- record missing: field `<field>` of record `<R>` cannot be omitted because its
  type `<type>` does not accept nil.

Do not collapse unsupported-target errors into “not a function,” and do not let
an old `.so` without name metadata degrade into all names being “unknown”; ABI
validation must catch it first.

## 6. Acceptance criteria

The feature is complete when all of the following are true:

- braces unambiguously denote named calls, and `f{}` is identical to `f {}`;
- all positional constructor arguments remain expressible with parentheses;
- direct local/imported functions, statics, methods, and `Rec.new` map names
  correctly;
- direct fixed-arity FFI functions map preserved C parameter names correctly,
  including keyword labels and zero-parameter calls;
- true zero-parameter calls and true zero-field records accept `{}` through
  local, source-import, and binary-interface paths where applicable;
- calls through function/C-pointer values, every variadic form, and FFI
  functions without complete names fail cleanly;
- missing formals and record fields share the existing nil-compatibility rule;
- a record's nil-compatible local fields fill inside its declaring module, while
  any local field makes every outside-module constructor form illegal;
- explicit expressions evaluate exactly once in lexical order despite formal
  reordering;
- names survive the C parser/type conversion and Titan source-loader/`.so`
  interface round trips but do not affect structural function types or native
  signatures;
- Lua calls remain positional and one-table calls are never inferred as named;
- the compiled interface/install ABI is consistently 0.13;
- both new manuals and all affected existing chapters describe the shipped
  behavior;
- the delegated `uv.titan`/facade migration builds and passes the complete
  library and bundled/system libuv mode gates;
- focused specs, `make test`, and `git diff --check` pass.

## 7. Principal risks and mitigations

- **Existing brace call sugar breaks.** Make the migration explicit, retain all
  constructor values under parentheses, update parser diagnostics, and audit
  fixtures/docs/examples.
- **Checker reordering changes effects.** Preserve a lexical formal-index map and
  materialize/convert explicit expressions before assembling the formal-order
  Titan or C call.
- **Names accidentally become types.** Store them only on intermediate parsed C
  declarations and Titan declaration/interface descriptors; leave structural
  `Type.Function`, `Type.CFunction`, equality, and tag generation untouched.
- **C prototype names are incomplete, conflicting, or header-version-dependent.**
  Publish names only for a complete unambiguous prototype set, keep positional
  calls available, and compile the `uv` dogfood source in bundled and system
  libuv modes on Linux/macOS.
- **C names collide with Titan keywords.** Use a raw identifier primitive only
  for the named-label-before-`=` position; do not weaken ordinary identifier
  rules or rename foreign parameters.
- **Old DSOs fail while evaluating metadata.** Bump to 0.13 and retain the ABI
  marker check before `_types` loading.
- **Named calls enter the wrong generic/foreign/vararg path.** Classify direct
  Titan versus direct C provenance in the checker, reject value/pointer/vararg
  calls, and assert the selected lowering in codegen.
- **FFI reordering drops conversions or post-call rooting.** Drive
  `codeforeignexp` and `mutable_out_anchor` from lexical order, retain them by
  formal index, and prove mutable-address behavior with a C fixture.
- **GC values die in reordered temporaries.** Use the existing typed
  `materialize_code`/stack-slot anchoring path and add collection-pressure
  runtime coverage.
- **Record omission bypasses privacy.** Reject every outside-module construction
  of a record with any local field before filling; inside the declaring module,
  deliberately apply filling to local and public fields alike.
- **Production dogfooding becomes an unreviewable compiler-plus-stdlib edit.**
  Delegate the bounded `uv`/facade refactor only after focused compiler tests are
  green, forbid compiler edits in that subtask, and review/validate its diff as a
  separate phase.

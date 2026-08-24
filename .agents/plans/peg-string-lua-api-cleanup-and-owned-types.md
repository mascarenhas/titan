# PEG/string Lua-API cleanup and source-nameable owned C storage

Status: implementation plan for the follow-up on
`agent/peg-string-standard-library`.

This plan starts from the implemented PEG/string standard-library work in
`.agents/plans/peg-and-string-standard-library.md` and the narrower historical
FFI note in `.agents/plans/c-ffi-lua-api-followup.md`. It does not reopen the
embedding, regex-dialect, or provider-layout design. It removes raw Lua-stack
work where Titan already has a typed operation, and adds the missing source
syntax needed to retain GC-owned C storage without pairing a bare pointer with
an otherwise untyped `value`.

The work has two primary tracks and one integration track:

1. Make the existing internal `Type.COwned` shape source-nameable as
   `owned *T` and `owned T[]`, and add a binary-safe counted-character-array to
   `string` cast.
2. Replace ordinary Lua-stack manipulation in `titan.peg` and `titan.string`
   with Titan calls, Arrays, Maps, casts, and `is`.
3. Apply the owned types throughout the standard library, especially
   `titan.uv`, deleting redundant pointer-plus-storage records and raw userdata
   allocation while preserving the places that carry a genuinely distinct
   logical length or lifetime.

The compiler/language work must land before the stdlib migrations that name
owned types or cast owned character arrays to strings.

## 1. Baseline and non-negotiable decisions

The current branch already establishes several decisions that this follow-up
must preserve:

- `titan.peg` has no `find` export. Module-level `peg.match` is the sole
  relabel search operation. It performs a leftmost search and returns a
  `Match?`, whose span and `values()` make it a strict superset of the removed
  position-only `peg.find`. `Pattern:match` remains the anchored native-pattern
  operation.
- `titan.string.find` is literal, binary-safe search;
  `titan.string.match` is regex search.
- `Regex:match` returns the typed `RegexMatch?`; the old value-projection
  method is gone because callers can use `RegexMatch:values()`.
- PEG and string public declarations and their implementations stay in the
  canonical `titan/peg/peg.titan` and `titan/string/string.titan` mains.
  Contributors retain only module-local top-level declarations.
- `format` is already parsed by a PEG that captures exact
  `(value) -> string` partial builders. Do not return to byte-code dispatch or
  magic integer constants for specifiers.
- String, regex, and relabel `gsub` take exactly a
  `(string) -> string` replacement callback receiving the whole match.
- `exp is T` already uses the same relation as the written `exp as T` cast,
  evaluates once, and does not narrow.
- Titan fixed-call adjustment already ignores surplus arguments. Do not make
  fixed APIs variadic merely to ignore extras.
- The nine standard-library roots are compiled and linked into one combined
  static/dynamic provider pair. A source import between standard modules does
  not add or avoid a separate PEG/native payload.

Use these additional decisions:

1. `owned` becomes a reserved Titan keyword.
2. `owned *T` means one GC-owned object whose payload has C type `T`.
   `owned T[]` means a dynamically counted GC-owned array of C `T`.
3. A trailing option marker applies to the complete owned value. Thus
   `owned *T?` is an optional owner, not an owner whose C payload type is an
   option. Declaration sugar such as `handle?: owned *T` remains equivalent
   and is often clearer for fields.
4. Source-written owned types lower to the existing
   `Type.COwned(pointee, count)` and existing `Udata *` representation. This is
   syntax and static typing for a representation that already exists, not a
   second ownership mechanism.
5. Only counted owned arrays whose typedef-resolved element is `char`,
   `signed char`, or `unsigned char` explicitly cast to `string`. The cast
   copies exactly the userdata payload byte length, including embedded NULs.
   Scalar owned characters do not acquire this conversion.
6. PEG grammar rule names and failure labels become strings. Integer names and
   labels are removed from the Titan API.
7. Failure labels pass to LPegLabel as their exact strings. The string
   `"fail"` denotes ordinary failure whether it originates in the engine or in
   an explicit `throw("fail")`; the two cases are intentionally
   indistinguishable. No private name/label encoding remains.
8. `grammar` takes an Array `{Rule}` and relabel `compile` takes an optional
   Array `{Definition}?`. Grammar rule names remain unique. Definition
   names also remain unique; the container change does not alter the existing
   duplicate-definition error.
9. Relabel replacement dispatch uses `replacement is integer`, not an exact
   Lua integer-tag probe. An integral representable float therefore selects
   the capture-index branch, consistently with Titan's cast predicate.
10. Weak semantics remain a narrow raw-Lua boundary until Titan has weak Maps,
    but table construction does not. Create both caches and their `__mode`
    metatables as typed Titan Maps, push those existing Maps only to call
    `lua_setmetatable`, then perform all cache access as ordinary typed Map
    access.
11. Existing UV owners that explicitly release their native storage at
    completion use optional owned fields and clear those fields at the same
    lifecycle point. Do not silently retain closed native allocations merely
    because doing so would remove an option cast.
12. `Buffer` still owns both its `uv_buf_t` descriptor and its byte array:
    `uv_buf_t.base` is a borrowed pointer and does not keep the bytes alive.
13. No general ABI migration machinery is added. These modules and the runtime
    are rebuilt together in the prototype. The source syntax and private
    owner-slot change do not require an ABI advance; if later work independently
    requires a bump, users clean and rebuild from scratch.
14. The existing explicit waiver for a manual macOS workflow on this branch
    remains in force. Final validation needs exact-head Linux, sanitizer, and
    Codecov evidence, but must not dispatch macOS unless the maintainer changes
    that instruction.

## 2. Scope

### 2.1 In scope

- Lexer, parser, AST, checker, type rendering, compatibility, and code
  generation for source-written owned C types.
- Owned types in local aliases, locals, module-private state, local fields,
  options, local callable parameters/results, closures, Arrays, and Maps.
- Continued rejection of every exported interface containing a C FFI type.
- Correct owned-to-pointer adjustment, including qualifier preservation and
  object-to-`void *` cases.
- A binary-safe counted-owned-character-array to `string` cast.
- Explicit casts from statically GC-backed Titan types and every FFI pointer
  shape to C `void *`, using the value's existing underlying pointer. The
  source value retains ownership of that non-rooting pointer.
- Function-type tag safety now that local function types can contain
  source-written C-owned types.
- Direct Titan invocation of the embedded LPegLabel callables.
- Typed PEG result storage that preserves nil and trailing-nil captures at the
  200-capture boundary.
- String-only PEG rules/labels, typed grammar construction, typed relabel
  definitions, and typed weak caches.
- Typed regex cache/table-capture access and Titan-created identity sentinels.
- Direct `as`/`is` use in format, `%q`, and pack.
- Removal of the generic `finish_string` helper from exact-size string
  builders.
- Replacement of ordinary stdlib `lua_newuserdatauv` allocations with
  `.new()`/`.new_array()`, except the custom coroutine userdata.
- Replacement of UV owner-record `lua_pushtvalue`/`lua_togco` round trips with
  the general GC-value-to-C-`void *` cast.
- Redesign of UV byte/address aliases, owner records, and the private native
  callback-slot protocol.
- Both manuals, tests, source transformers, implementation guidance, provider
  rebuild, and exact-head CI evidence.

### 2.2 Out of scope

- A general weak-Map language feature.
- An owned slice/view type or general pointer-plus-length string conversion.
- User-defined finalizers or uservalues on owned C allocations.
- Treating arbitrary dynamic `value` as necessarily pointer-backed; immediate
  integers, floats, booleans, and nil have no underlying GC pointer. Options
  must likewise be unwrapped before using the base type's pointer conversion.
- Migrating coroutine's minicoro userdata, which needs four uservalues, a
  custom metatable/finalizer, and an external `mco_coro **` output slot.
- General Lua C API annotations, stack-effect checking, callbacks, or macro
  import.
- Exposing C FFI types through serialized module interfaces.
- Making owned values themselves nullable. Optionality remains the ordinary
  Titan `Option` wrapper around a non-null `COwned`.
- Replacing the pinned LPegLabel engine or changing the regex grammar. One
  narrow vendored adapter fix is in scope: labeled failures retain their
  original Lua value instead of coercing numeric-looking strings to integers,
  so Titan's string-only labels preserve their exact bytes.
- Restoring `peg.find`, adding `Regex:find`, or adding a PEG analogue of
  literal `string.find`.
- Reproducing every Lua coercion accepted by `luaL_check*`; the tightened
  string APIs deliberately use Titan cast semantics.
- A compatibility layer for stale generated stdlib files or an ABI migration
  path.

## 3. Current repository evidence

| Area | Current source | Problem to remove or invariant to preserve |
| --- | --- | --- |
| PEG match boundary | `titan/peg/peg.titan:101-174` | Manually pushes a callable and arguments, calls `lua_pcallk`, copies stack results into a raw table, and restores the top |
| PEG engine bootstrap | `titan/peg/native.titan:3-74` | Opener/registry access is legitimate, but field lookup and callable storage remain unnecessarily raw |
| PEG name/label encoding | `titan/peg/native.titan:95-156` | Supports integer identity and private encoding that the string-only API no longer needs |
| PEG grammar | `titan/peg/peg.titan:197-249` | Iterates a public integer-keyed Map through `lua_next` and constructs the native grammar table on the Lua stack |
| Relabel cache/slices | `titan/peg/relabel.titan:40-125` | Raw cache gets/sets, raw pointer-length strings, and raw userdata for spaces |
| Relabel definitions | `titan/peg/relabel.titan:193-269` | Revalidates Array-like density through `lua_next`, rejects unwritable names, and constructs the environment on the stack |
| Relabel replacement | `titan/peg/relabel.titan:430-442` | Retains an exact Lua integer-tag helper instead of the requested cast predicate |
| Regex cache/results | `titan/string/regex_api.titan:15-105` | Raw weak-cache access, raw sentinel creation, and one raw table lookup per captured slot |
| Format/pack checks | `titan/string/format.titan:63-89`, `titan/string/string.titan:244-324` | `luaL_check*` wrappers duplicate Titan casts and preserve unwanted Lua coercions |
| Exact string builders | `titan/string/bytes.titan:17-24` and its callers | Every owned character buffer is reduced back to a pointer/count and pushed through Lua |
| Existing owned substrate | `titan-compiler/types.lua`, `checker.lua`, `coder.lua`, `cdeclarator.lua` | `.new()` and `.new_array()` already produce `Type.COwned`, but source annotations cannot spell it |
| UV native storage | `titan/uv/{runtime,task,file,os,process,tcp}.titan` | Fifteen ordinary allocations pair a bare pointer with a `value` storage field |
| UV callback slots | `titan-runtime/titan/uv.h:42-68`, `titan-runtime/titan_uv.c:18-34` | Fixed six-slot private layout includes a now-redundant storage slot |
| Custom exception | `titan/coroutine.titan:245` | Raw userdata is semantically required and must remain |
| PEG search API | `titan/peg/peg.titan:635-661` | Already implements the desired `match`-only leftmost search; guard against reintroducing `find` |

The source audit found 17 stdlib `lua_newuserdatauv` call sites: fifteen
ordinary UV allocations, one temporary relabel character buffer, and the one
custom coroutine allocation. The first sixteen are removed by this plan; the
coroutine allocation remains.

## 4. Track A: source-nameable owned C types

### 4.1 Lexing and parsing

Reserve `owned` in `titan-compiler/lexer.lua`. Before enabling the keyword,
rename every Titan identifier currently spelled `owned`, including embedded
Titan snippets in specs. Lua variables, comments, strings, and a logical module
path such as `owned.item` are not Titan identifier uses and need not be renamed.

Add an AST node beside `Ast.TypeCPointer` and `Ast.TypeCArray`:

```lua
TypeCOwned = {"loc", "subtype", "count"}
```

Parse these source forms:

```titan
owned *c.Item       -- one owned c.Item
owned c.Item[]      -- counted owned c.Item array
owned **c.Item      -- one owned *c.Item pointer object
owned *c.Item[]     -- counted owned array of *c.Item
owned *c.Item?      -- optional owner of one c.Item
```

The first `*` in the scalar form is the ownership spelling and is not part of
the payload type. Any additional pointer layer belongs to the payload. In the
array form, the type before `[]` is the element type.

Implement this with an optionless owned-type base and apply the optional suffix
after the complete owned production. Put the array alternative before the
scalar alternative so `owned *c.Item[]` is the array-of-pointer shape, not a
scalar owner followed by rejected tokens. Do not let `?` become part of the C
payload type.

Add parser diagnostics for:

- `owned c.Item` without either the scalar `*` marker or array `[]`;
- missing type after `owned *`;
- missing `]`;
- applying `owned` to an ordinary Titan type;
- nested owned storage;
- fixed extents such as `owned c.Item[4]`, which remain outside the dynamic
  owner syntax.

Update lexer/parser AST fixtures with locations and recovery cases, not only
happy-path parse snapshots.

### 4.2 Checker construction and allocation eligibility

Add an `Ast.TypeCOwned` visitor next to the C pointer/array visitors in
`titan-compiler/checker.lua`. Resolve the payload through the current module's
foreign namespace, require a C object type, and lower directly to:

```lua
types.COwned(payload, node.count)
```

Extract the existing `.new()`/`.new_array()` eligibility rules into one shared
checker helper and use it for source-written owned types as well. Accept
complete allocatable C object shapes, including primitive, pointer, struct, and
union objects. Reject:

- `void`;
- a direct C function type (`sizeof(function)` must never reach generated C);
- incomplete structs/unions;
- C array typedefs;
- structs with flexible array members;
- a `CModule` namespace;
- a Titan type or another `COwned`.

Keep `.new()` and `.new_array(1)` distinct: the former has scalar owner type,
the latter counted-array owner type.

Allow an owned type wherever a local C type can soundly exist:

- local type aliases;
- local variables and constant module initializers;
- local fields of nominal records, including local fields on otherwise public
  records;
- local functions, methods, lambdas, and their parameters/results;
- options, closure captures, Arrays, and Maps inside the same source module.

Continue routing every public module variable, function/method signature,
public alias, and public record field through
`reject_exported_c_ffi_types`. Add explicit negative tests for an owned type
nested below an option, Array, Map, alias, or function type so serialization
cannot be bypassed by composition.

### 4.3 Canonical type identity and function tags

Change `types.tostring(Type.COwned)` to preserve shape:

```text
owned *T
owned T[]
```

The current `"owned T"` spelling makes unequal scalar and counted owners print
the same text. Update diagnostics, `spec/types_spec.lua`, implementation docs,
and the owned-metatable key helper to use one canonical renderer rather than
manually appending `[]` in a second place.

Source-nameable owned parameters/results expose an existing registry-key risk:
function type tags are globally shared by their rendered type, while imported
C typedefs are module-local. Two modules can import unrelated C types with the
same spelling and otherwise produce the same local function-type text. A
function value crossing through `value` must not take the exact native fast
path under the other module's C interpretation.

Keep globally shared tags for C-free Titan function types. Scope a function
tag containing any C FFI type to its defining module (or equivalently include
the module's C-type identity in the registry key). Add a two-module runtime
test in which same-spelled but unrelated owned C function types cross through
`value`; the call must take the generic checked path and reject the wrong owned
metatable instead of entering a mismatched native function.

### 4.4 Pointer adjustment and qualifiers

Reuse the existing `COwned -> CPointer` code generation that extracts
`getudatamem(owner)`. Correct the static compatibility arm so it has the same
qualifier-inclusion discipline as ordinary pointer/array decay:

- an owner of mutable `T` adjusts to `T *`, `const T *`, and permitted
  `void *` forms;
- an owner whose typedef-resolved payload is const never adjusts to a pointer
  that discards const;
- counted arrays adjust to compatible element pointers;
- scalar owners and counted owners do not become interchangeable;
- an optional owner must be explicitly unwrapped before pointer adjustment.

Exercise direct calls, C varargs, field access, pointer arithmetic where the
payload itself is a pointer, and assignment to compatible local pointer
variables. Preserve the owner root across every C call for which the adjusted
pointer is live.

### 4.5 Counted character arrays as binary strings

Extend the written-cast relation only for:

```text
Type.COwned(count = true, pointee = typedef-resolved character type)
    -> string
```

Accept C `char`, `signed char`, and `unsigned char`, including typedef chains
and legal qualifiers. Reject scalar owners and every non-character array.

Lower the cast by materializing and rooting the `Udata *` owner, then calling:

```c
luaS_newlstr(
    L,
    (const char *)getudatamem(owner),
    owner->len)
```

Use the existing length-aware string-construction helper in the coder rather
than the raw-pointer NUL-terminated cast arm. The owner must remain rooted
across allocation even for a temporary expression such as
`ffi.titan_ffi_char.new_array(n) as string`.

Tests must cover:

- zero length;
- one byte;
- embedded and trailing NUL;
- signed/unsigned/plain character aliases;
- a temporary owner under forced full and generational GC;
- an owner stored in a local field, option, closure, and module variable;
- `owner is string`, including exactly-once operand evaluation;
- rejection of scalar character owners and non-character arrays;
- the unchanged NUL-terminated semantics of
  `(owner as *ffi.titan_ffi_char) as string`.

### 4.6 GC and FFI pointers as C void pointers

Allow an explicit cast to C `void *` from every statically GC-backed Titan
value and every FFI pointer shape, including through Titan aliases and C
typedefs of `void *`. Use the existing underlying representation pointer:

- `string` keeps its established byte-pointer conversion;
- Arrays and Maps use their `Table *`;
- nominal records use their `Udata *`;
- function values use their underlying collectable closure/callable pointer,
  rejecting a malformed noncollectable function-typed value at the cast;
- ordinary C object and function pointers use their C pointer value;
- `COwned` keeps its existing payload-pointer adjustment through
  `getudatamem`, rather than changing to the owner Udata identity.

Materialize the operand once and keep a GC source rooted while deriving and
using the address during argument setup. The raw pointer does not retain its
source. Code that stores it in an external library must separately keep the
source reachable until the final native use. Arbitrary dynamic `value` and an
unwrapped option are not statically guaranteed to have an underlying pointer.

Tests must cover aliases, C `void *` typedefs, every representation above,
exactly-once evaluation, identity stability, malformed deferred-callable
values, the existing `COwned` payload behavior, and the absence of an implicit
conversion.

### 4.7 Track A documentation

Update both manuals in the same compiler change:

- `doc/language/ffi.md`: syntax, allocation correspondence, pointer adjustment,
  `#`, indexing, options, and binary string casts.
- `doc/language/c-ffi-expressions.md`: compatibility, qualifiers, and examples
  in fields/callables, plus the explicit GC/FFI-pointer conversion and its
  lifetime rule.
- `doc/language/grammar.md`: `owned` keyword and exact type grammar.
- `doc/language/types.md`, `option-types.md`, and `type-aliases.md` where their
  composability tables currently omit owned types.
- `doc/implementation/ffi-internals.md`: AST lowering, `COwned` representation,
  metatable identity, character cast, GC/FFI `void *` conversions, rooting,
  and function-tag scoping.
- `doc/implementation/c-ffi-expressions.md`,
  `ast-typedecl.md`, and `checker.md` for the new node and validation path.
- `doc/language/index.md` and `doc/implementation/index.md` summaries only as
  needed; no new chapter is required because the feature belongs to the
  existing FFI chapters.

Update the owned-storage paragraph in `AGENTS.md` after implementation so it
states that persistent pointer-plus-`value` pairs should use a source-written
owned type, while preserving the documented exceptions for logical slices,
borrowed pointers, custom uservalues/finalizers, and heterogeneous roots.

## 5. Track B: PEG and string without ordinary raw stack work

### 5.1 Type the embedded engine after its unavoidable bootstrap

The private C opener still receives `L` and leaves the module table on the Lua
stack. The private pattern metatable still lives in the Lua registry. Keep
those two boundary operations in `_initialize_native`.

Immediately cast the opener result and registry metatable to typed Titan Maps.
Fetch their members with ordinary indexing. Give stored engine operations
precise local callable types rather than `value`; at minimum distinguish:

- constructors/operators with fixed inputs/results;
- vararg constructors such as range and constant capture;
- locale and stack-limit operations;
- native `match`.

The values are Lua C closures, so generated calls correctly take Titan's
generic callable path. Function-typed casts intentionally do not preflight
callability; a corrupt private pinned engine fails when invoked. Delete
`_field` and `_require_function` rather than retaining a Lua type probe solely
for an earlier error.

Create success and regex/backreference identity sentinels as ordinary
Titan-created GC values in the module initializer, not with
`lua_createtable`.

### 5.2 Call native match directly and preserve all results

Type `_match` as:

```titan
local type NativeMatch =
  (value, string, integer, ...: value) ->
    (value, value, ...: value)
```

The two fixed results are required. The success wrapper returns:

```text
success sentinel, 0..200 user captures, final position
```

At 200 captures that is 202 total native results, but only 200 values in the
flexible tail. An all-flexible return type would exceed Titan's 200-value tail
limit and regress the documented maximum.

Call `_match(raw, subject, start, ...)` directly and capture all results with a
Titan `{ <call> }` Array. Do not use `lua_pcallk`, manually push arguments,
inspect `lua_gettop`, or rebuild a result table. Ordinary Titan error
propagation already reaches the nearest `catch`; add a catch only if the code
translates the error, not merely to re-raise it.

Keep the complete wrapped result Array, including the final non-nil position.
That final value makes its logical length reliable even when user captures
contain holes or end in nil. Store an explicit capture count and project
captures from slots `2..capture_count+1`; do not copy them into a second Array
whose trailing nils would cease to contribute to length.

Tighten `PatternMatchAttempt` and `Match` storage from `value` to `{value}` and
delete `_raw_table_item`. `Pattern:match` and `Match:values` can recursively
return direct Array indices while preserving exactly zero results, leading
nil, interior nil, and trailing nil.

Keep the success sentinel plus final-position wrapper. Without it, a successful
capture tuple beginning with `nil, "fail", integer` is ambiguous with a native
failure triple.

### 5.3 Make names and labels direct strings

Change:

```titan
function rule(name: string, pattern: Pattern): Rule
function grammar(start: string, rules: {Rule}): Pattern
function variable(name: string): Pattern
function throw(label: string): Pattern
```

Store a raw string name in `Rule`. Grammar names and failure labels go straight
to LPegLabel as string values. Delete `_encoded_name`, `_decoded_label`, their
substring/integer parsing, and every private prefix.

The engine's ordinary-failure label and an explicit `throw("fail")`
deliberately collapse to the same public `"fail"` result. Module-level
leftmost search therefore advances after either form. Implement
`throw("fail")` as the ordinary failure pattern itself so choice, repetition,
and grammar recovery cannot distinguish its origin; do not merely normalize
the returned failure triple. Every other thrown string remains a committed
labeled failure. Test empty, decimal-looking, binary, and `"fail"` labels.
Passing an integer from Titan is a static error and from Lua is a boundary
type error.

In relabel source, normalize a decimal failure-label token to its captured text
rather than an integer. Numeric repetition counts and numeric replacement
selectors remain integers; only labels change.

### 5.4 Build grammars and relabel environments as Titan tables

Change public grammar rules to `{Rule}`. Iterate `1..#rules`, enforce the
existing `MAX_RULES`, reject duplicate structural rule names, check that the
start name exists, and accumulate tree size. There is no longer a density
scan: Array construction and mutation enforce the Array invariant.

Build the mixed native grammar as `{value:value}`:

```titan
native[1] = start
native[rule.name] = rule.pattern.raw
```

Pass the Map directly to `_P`.

Change relabel compile definitions to `{Definition}?`. Build:

```titan
local native: {string:value} = {}
local sizes: {string:integer?} = {}
```

Iterate in Array order and reject a duplicate name before writing either map,
preserving the existing public error. Pattern definitions write both the raw
pattern and its projected tree size; dynamic-value definitions write the
value and leave no size entry.

Delete `_relabel_valid_name`. Empty, punctuation, whitespace, binary, and other
names outside `[A-Za-z_][A-Za-z0-9_]*` may be constructed but are unreachable
from relabel source and therefore inert. Keep `define_value`'s nil/false
rejection.

This Array API deliberately stops accepting an ordinary Lua table where a
Titan Array proxy is required. Rewrite Lua-driven runtime fixtures to obtain
rules/definitions through a compiled Titan helper. Document the Titan API
rather than retaining `lua_next` solely for Lua-table convenience.

### 5.5 Create weak caches as typed Titan Maps

Create each cache at its actual semantic Titan Map type:

```titan
{string: Pattern}
{string: Regex}
```

Create a typed `{string: string}` metatable containing `["__mode"] = "v"`.
Push the semantic cache and that metatable through the FFI only to call
`lua_setmetatable`. The call mutates the cache in place; do not use a
placeholder Map type, an intermediate `value`, or a cast back to the semantic
type. String installs the metatable on its existing module cache once. Each PEG
locale refresh constructs a fresh `{string: Pattern}` cache, installs the weak
metatable, and assigns that correctly typed Map directly so locale-dependent
compiled sources cannot survive the refresh.

Use ordinary Map reads/writes in:

- relabel's source compilation cache;
- the regex expression cache.

Delete `_relabel_raw_get`, `_relabel_raw_set`, `regex_cache_get`,
`regex_cache_put`, the Lua-created-table factories, and equivalent raw item
helpers once each has only a direct Map operation left. Preserve cache
invalidation when `update_locale()` rebuilds the locale-sensitive relabel
parser. The ASCII regex cache can be initialized once in `titan.string`'s
final `do ... end`.

### 5.6 Replace pointer-length string helpers where an exact owner suffices

After Track A:

- delete `_string_from` with the removed encoded-label machinery;
- `_relabel_slice` allocates an exact counted character array, copies the
  selected bytes, and casts that owner to `string`;
- `_relabel_spaces` allocates `new_array(count)`, fills it, and casts it;
- no relabel helper calls `lua_newuserdatauv` or `lua_pushlstring`.

These are exact copies. Do not apply the same rule to a logical prefix of a
larger allocation without either retaining its explicit length or making an
exact copy.

### 5.7 Tighten relabel and regex dynamic values

Replace `_is_integer_value(replacement)` with
`replacement is integer`, followed by `replacement as integer`.
Integral representable floats now select a capture index. Update the old test
that expected such a value to fall through to a callable error.

Keep dispatch order:

1. string template;
2. integer capture index;
3. `{value:value}` query Map;
4. function callback fallback.

The final function cast remains deliberately unchecked until invocation.

In `regex_attempt`, cast the LPeg table capture once to
`{integer:value}` and index it directly. Delete `regex_raw_table_item`.
Replace the raw-created regex group sentinel with a Titan-created unique
identity value. Preserve unmatched-group, backreference, nested capture, and
200-group behavior.

### 5.8 Replace format/pack `luaL_check*` wrappers with casts

Delete:

- `checked_integer`;
- `checked_number`;
- `checked_string`;
- `value_is_integer`.

Inline direct casts at every caller in both `format.titan` and the public
`pack` implementation in `string.titan`:

```titan
candidate as integer
candidate as float
candidate as string
candidate is integer
```

Use the imported exact C scalar type only at the C call boundary when needed;
do not keep a raw Lua check merely to produce `lua_Integer`/`lua_Number`.

This is an intentional Titan API change:

- numeric conversions accept actual integers or representable integral floats,
  not numeric strings;
- floating conversions accept actual numbers, not numeric strings;
- `pack` string options require an actual string and no longer convert numbers
  to strings;
- `%s` still uses this module's `tostring` and therefore still accepts any
  value and honors `__tostring`;
- `%q` checks the integer cast before the float cast, so an integral float is
  rendered through the integer branch.

Revise parity tests and the language manual to compare with Lua only for the
values Titan admits, then add explicit rejection tests for the removed
coercions.

### 5.9 Remove generic `finish_string` but retain logical-prefix boundaries

Replace every exact-size owned character buffer with a direct owner-to-string
cast:

- `copy_interval`;
- `reverse`, `lower`, `upper`, `rep`, and `char`;
- builder completion and zero-byte generation;
- decimal escaping and locale-neutral hexadecimal;
- integer/float/number/double pack results;
- exact relabel and label-copy buffers.

Delete `finish_string`.

Do not cast a larger allocation when only a logical prefix is valid:

- `snprintf` allocates `required + 1` bytes for its terminator, while its result
  is the first `required` bytes and may itself contain NUL from `%c`;
- libuv stream buffers have capacity larger than `nread`;
- OS sizing helpers return a logical result length;
- NUL-terminated `Text` owns `#source + 1` bytes but represents `source`.

Keep one specialized, owner-rooted formatter finalizer for `snprintf`. After
checking that the actual result equals `required`, copy the first `required`
bytes into an exact-length owned array and cast that result directly to
`string`. This deliberately pays one extra copy so the standard library does
not manipulate the Lua stack; it also makes zero length ordinary Titan code.
Its name and signature must make the prefix distinction explicit, and tests
must retain `%c(0)` so a later NUL-terminated pointer cast cannot silently
replace the counted copy.

Retain:

- `luaL_tolstring` for `titan.string.tostring` and `%s`;
- `lua_topointer` for `%p`.

Those operations have no equivalent Titan primitive and are the intended raw
boundary.

### 5.10 Preserve the `peg.match`-only API

No implementation rename is needed because the branch already has the desired
surface. Treat the following as acceptance requirements:

- no public `peg.find`;
- module-level `peg.match(subject, candidate, init)` performs leftmost search;
- it accepts a source expression or compiled `Pattern`;
- it returns `Match?`, including empty spans and the candidate's complete
  captures;
- labels other than `"fail"` stop search, while ordinary failure and an
  explicit `"fail"` advance it;
- `Pattern:match` remains anchored and exposes the native failure triple.

Keep the export inventory in `spec/libuv_build_spec.lua` explicit. Add a
negative member/API check if needed so a later contributor cannot reintroduce
`find`. Change the PEG entry in `doc/language/index.md` from only “anchored
matching” to “anchored pattern matching and leftmost search.”

## 6. Track C: stdlib migration to owned aliases and fields

### 6.1 Exact string buffers

Use a local readability alias where a function must name the owner:

```titan
local type CharBytes = owned ffi.titan_ffi_char[]
```

Do not recreate a `StringBytes`/`Bytes` record containing pointer, storage, and
length when the allocation count is the exact logical length. Pass the owner
directly, use `#owner`, and let pointer contexts adjust it.

Rename existing local variables named `owned` before the keyword lands.

### 6.2 UV byte and address storage

Replace the current `Bytes` record with:

```titan
local type Bytes = owned ffi.titan_ffi_char[]
```

Delete `allocate_bytes`; use
`ffi.titan_ffi_char.new_array(length)` directly. Rewrite:

- `copy_text` to allocate `length + 1`, copy, terminate, and retain both the
  owner and original source in `Text`;
- `copy_bytes` to return an exact owner;
- stream allocation to return the owner directly;
- `make_buffer` to use `libuv.uv_buf_t.new()`.

Keep:

```titan
local record Buffer
  local handle: owned *libuv.uv_buf_t
  local bytes: Bytes
end
```

The two owners are not redundant: the descriptor borrows the byte pointer.

Read capacity and logical bytes read are different. Introduce a narrow record
for queued partial reads:

```titan
local record ByteChunk
  local bytes: Bytes
  local length: integer
end
```

Use `Bytes?` while a libuv read is pending and `{ByteChunk}` after a callback
queues `nread`. Do not cast the full capacity to string. Consolidate
`bytes_string`/`bytes_to_string` into one length-aware helper that keeps the
owner alive (when applicable) and copies exactly the logical prefix.

Replace:

```titan
local record AddressList
  local data: *shim.titan_uvshim_address
  local storage: value
  local count: integer
end
```

with:

```titan
local type AddressList =
  owned shim.titan_uvshim_address[]
```

Use `#addresses` for count and ordinary pointer adjustment for traversal. The
delayed-DNS variant's optional leading invalid cell remains representable
because its physical allocation count is also its logical test count.

### 6.3 UV loop/request/handle owners

Replace each raw allocation with the imported type constructor and store the
owner itself:

- `titan/uv/runtime.titan`: `uv_loop_t`, `uv_buf_t`, and byte arrays;
- `titan/uv/task.titan`: `uv_timer_t`;
- `titan/uv/file.titan`: `uv_fs_t`;
- `titan/uv/os.titan`: `uv_signal_t`;
- `titan/uv/process.titan`: `uv_process_t`, `uv_pipe_t`, `uv_write_t`, and the
  grace `uv_timer_t`;
- `titan/uv/tcp.titan`: `uv_getaddrinfo_t`, `uv_connect_t`, `uv_write_t`,
  `uv_shutdown_t`, and `uv_tcp_t`.

For example:

```titan
record uv_timer_t
  local handle?: owned *libuv.uv_timer_t
  local main_thread: value
  local dispatcher: (...)
  local metadata: ...
  local buffer: ...
end
```

The exact remaining fields differ by owner family, but their order must match
the private callback protocol. Allocate with `libuv.uv_timer_t.new()`, pass the
owner directly where `*libuv.uv_timer_t` is expected, and remove the parallel
`storage: value`.

Where current code clears both `handle` and `storage`, clear the optional owner
at the same point after native cleanup/close. Where a descriptor is guaranteed
live for the record's whole lifetime, use a nonoptional owner. Preserve all
lifecycle checks before unwrapping an optional owner.

Do not change callback data ownership: `uv_*_set_data` still stores the Titan
owner record's `Udata *`, not the native allocation's owner. Derive that
identity with the explicit `owner as ffi.titan_ffi_void_ptr` cast and retain
the owner through the existing Runtime/control links for the complete native
lifetime. Delete the former `lua_pushtvalue`/`lua_togco` stack round trip from
every ordinary UV owner allocator.

### 6.4 Five-slot native callback protocol

Remove the redundant storage field from the fixed private callback layout in
one atomic change across:

- `titan-runtime/titan/uv.h`;
- `titan-runtime/titan_uv.c`;
- every callback-owner record in `titan/uv/`;
- comments and enums in those sources;
- delayed DNS/FS source transformers;
- `doc/implementation/libuv-runtime.md`;
- specs that assert owner layout or source anchors.

The target layout is:

| Lua/source slot | C index | Meaning |
| --- | --- | --- |
| 1 | 0 | owned native handle/request |
| 2 | 1 | main Lua thread |
| 3 | 2 | Titan dispatcher closure |
| 4 | 3 | family metadata/control |
| 5 | 4 | family-specific buffer/root or nil |

The native trampoline reads only main-thread and dispatcher slots, but keep
the full enum/count as the shared layout contract and update every “fixed
six-slot” assertion/comment to “fixed five-slot.”

This is coordinated stdlib/runtime state inside the combined provider. Public
record serialization still counts local fields, so the six-to-five field
change updates `titan.uv`'s type protocol and must be rebuilt together with
the other roots; it does not add a separately loadable native component or
require an ABI migration path.

### 6.5 Retained records and raw boundaries

Do not remove a record merely because it contains an owned value. Retain:

- `Text`, because it couples a NUL-terminated owner with the original logical
  source string;
- `Buffer`, because it roots two allocations with a borrow between them;
- `ByteChunk`, because `nread` differs from capacity;
- process argv ownership/count metadata, because the native array includes a
  final null sentinel that public `argc` excludes;
- operation/control records carrying lifecycle, callbacks, linked-list
  ownership, or heterogeneous roots;
- coroutine's custom userdata allocation.

After this track, remaining raw stdlib Lua API use is justified by one of:

- custom userdata uservalues/finalizer;
- Lua main-thread/registry access;
- embedded LPegLabel opener/private registry;
- attaching a weak metatable to Titan-created typed cache Maps;
- `luaL_tolstring`;
- `lua_topointer`;
- an explicit pointer/owner plus logical-length string copy where capacity is
  not the result length.

### 6.6 UV fixture and implementation docs

Rewrite `spec/stdlib/uv_native_handles_spec.lua` around a complete imported
fixture type (or public complete `uv_timer_t`) and `.new()`. Remove the
runtime-sized incomplete-type allocation and the `lua_newuserdatauv` macro
interposition that existed solely for the old implementation. Keep the
cross-module no-boxing assertion after the initial owner allocation.

Remove the now-unused `titan_uv_test_timer` typedef and
`titan_uv_test_timer_size()` fixture declarations/implementation if no other
test consumes them.

Update:

- `doc/implementation/libuv-runtime.md`;
- `doc/implementation/libuv-networking.md`;
- the relevant language stdlib chapters only where ownership is part of a
  public guarantee;
- `AGENTS.md`'s callback-slot and owned-storage descriptions.

## 7. File-by-file implementation map

### Compiler

- `titan-compiler/lexer.lua`
  - reserve `owned`.
- `titan-compiler/ast.lua`
  - add `Ast.TypeCOwned`.
- `titan-compiler/parser.lua`
  - parse scalar/counted owned types with correct `[]`/`?` precedence.
- `titan-compiler/checker.lua`
  - lower/validate written owners;
  - share allocation eligibility;
  - preserve export rejection;
  - add owned-character and GC/FFI-pointer-to-C-`void *` cast relations.
- `titan-compiler/types.lua`
  - canonical rendering;
  - qualifier-safe pointer adjustment;
  - helpers for counted character owners/C-bearing function types.
- `titan-compiler/cdeclarator.lua`
  - verify the existing `Udata *` declaration path needs no new representation.
- `titan-compiler/coder.lua`
  - binary owner-to-string lowering and rooting;
  - GC/FFI underlying-pointer lowering and rooting;
  - module-scope C-bearing function tags;
  - reuse existing owned pointer/index/length/allocation paths.

### PEG/string production sources

- `titan/peg/peg.titan`
  - typed engine state, direct match, typed results, Array grammar, string APIs,
    and `match`-only public search.
- `titan/peg/native.titan`
  - retain only bootstrap/registry raw work; remove ordinary field/result/name
    helpers.
- `titan/peg/relabel.titan`
  - typed weak cache, exact owned copies, Array definitions with duplicate
    rejection, unwritable names, and `is integer`.
- `titan/peg/relabel_parser.titan`
  - textual numeric failure labels and any tighter callback types.
- `titan/string/bytes.titan`
  - delete `finish_string`; exact owner casts.
- `titan/string/format.titan`
  - direct casts/predicates, exact owner casts, specialized prefix finalizer.
- `titan/string/pack.titan`
  - exact owner casts.
- `titan/string/regex_api.titan`
  - typed cache, sentinel, and captured Map access.
- `titan/string/string.titan`
  - direct format/pack casts, exact public string builders, invariant
    initialization.
- `vendor/lpeglabel/lpltree.c`
  - preserve numeric-looking labeled failures as strings instead of applying
    the upstream integer coercion.
- `vendor/lpeglabel/UPSTREAM.md`
  - record the narrow local label-preservation patch.

### UV/runtime production sources

- `titan/uv/{uv,runtime,task,file,os,process,tcp}.titan`
  - aliases, owned fields, direct constructors, lifecycle clears, five-slot
    ordering, retained logical-length records, and direct owner-record identity
    casts for callback data.
- `titan-runtime/titan/uv.h`
  - five-slot enums/comments.
- `titan-runtime/titan_uv.c`
  - shifted main-thread/dispatcher indices and comments.
- `titan/coroutine.titan`
  - no allocation change; only rename a conflicting identifier if the new
    keyword requires it.

### Specs/support

- `spec/lexer_spec.lua`, `spec/parser_spec.lua`, `spec/types_spec.lua`.
- Add focused `spec/checker/c_ffi_owned_types_spec.lua`.
- Add focused `spec/coder/c_ffi_owned_types_spec.lua`.
- `spec/support/ci_test_groups.sh`
  - keep the new C-FFI checker/coder files in the explicit heavy compiler
    cohort.
- `spec/stdlib/{peg,peg_relabel,string,string_regex}_spec.lua`.
- `spec/libuv_build_spec.lua` export/source inventory.
- `spec/stdlib/uv_native_handles_spec.lua`.
- UV timer/fs/net/OS/process/library suites affected by owner changes.
- `spec/support/make_delayed_dns_callback_variant.lua`.
- `spec/support/make_delayed_fs_callback_variant.lua`.
- `spec/fixtures/stdlib/native/titan_uv_test_allocation.{h,c}` if their old
  incomplete timer allocation is removed.
- Every embedded Titan fixture containing `owned` as an identifier.

### Manuals/instructions

- Language: `ffi.md`, `c-ffi-expressions.md`, `grammar.md`, `types.md`,
  `option-types.md`, `type-aliases.md`, `standard-library-peg.md`,
  `standard-library-string.md`, and `index.md`.
- Implementation: `ffi-internals.md`, `c-ffi-expressions.md`,
  `ast-typedecl.md`, `checker.md`, `lpeglabel-embedding.md`,
  `string-library.md`, `libuv-runtime.md`, `libuv-networking.md`,
  `ffi-lua-api-followup.md`, and `index.md` where needed.
- `AGENTS.md`: source-nameable owner rule, five-slot protocol, retained
  exceptions, and the sibling-audit requirement.

## 8. Implementation phases

### Phase 0 — freeze the tightened contracts

1. Record the `peg.match`-only export inventory and leftmost-search tests.
2. Add failing parser/checker/coder cases for owned syntax and binary casts.
3. Add failing strict-format/pack and string-only PEG label cases.
4. Add source audits for current raw helpers and all stdlib
   `lua_newuserdatauv` sites.
5. Rename Titan identifiers that will conflict with `owned`.

### Phase 1 — add source-written owned types

1. Land lexer, AST, parser, and checker construction.
2. Share allocation eligibility and close the direct-C-function rejection.
3. Land canonical rendering and export-composition rejection.
4. Correct qualifier-safe pointer adjustment.
5. Scope C-bearing function tags and add the cross-module adversarial case.
6. Run lexer/parser/types/checker gates before touching stdlib sources.

### Phase 2 — add counted-character-owner string casts

1. Extend the written-cast relation.
2. Lower through `luaS_newlstr` with `Udata.len`.
3. Prove temporary-owner rooting and binary lengths.
4. Add the explicit GC/FFI-pointer-to-C-`void *` relation and prove each
   representation, once-only evaluation, and lifetime contract.
5. Update FFI language/implementation manuals.
6. Run focused coder tests and the existing complete C FFI suites.

### Phase 3 — remove ordinary PEG raw stack work

1. Type engine Maps/callables after bootstrap.
2. Direct-call native match with the two-fixed-plus-flex result type.
3. Store complete result Arrays and rewrite `Pattern:match`/`Match:values`.
4. Narrow names/labels to direct strings and fold explicit `"fail"` into
   ordinary failure.
5. Change grammar rules and relabel definitions to Arrays.
6. Convert relabel caches/slices/spaces and replacement dispatch.
7. Update PEG docs and all PEG/relabel tests.

### Phase 4 — remove ordinary string raw stack work

1. Convert regex cache/sentinel/capture access.
2. Delete format/pack check wrappers and revise coercion behavior.
3. Replace exact buffer finalization with owned casts.
4. Retain and test only the specialized prefix conversion, `tostring`, and
   `%p` raw boundaries.
5. Run string, regex, PEG/string shard, and binary/GC stress tests.

### Phase 5 — migrate UV arrays and logical slices

1. Introduce `Bytes`/`AddressList` aliases.
2. Introduce `ByteChunk` for partial queued reads.
3. Rewrite `Text`, `Buffer`, stream reads, OS sized buffers, and DNS address
   traversal.
4. Update delayed DNS anchors immediately with the source change.
5. Run focused net/process/OS and delayed-DNS tests.

### Phase 6 — migrate UV handles and callback layout

1. Replace all ordinary handle/request allocations with `.new()`.
2. Convert pointer/storage pairs to owned or optional-owned fields.
3. Replace every ordinary owner-record `lua_pushtvalue`/`lua_togco` pair with
   the direct GC-value pointer cast.
4. Preserve close/cleanup ordering and callback data ownership.
5. Shift the native protocol to five slots in the same commit.
6. Rewrite the native-handle fixture and delayed FS anchors.
7. Run timer, fs, net, OS/process, late-callback, native-handle, and sanitizer
   gates.

### Phase 7 — close documentation, audits, and publication

1. Reconcile both manuals and `AGENTS.md` with the final code.
2. Rebuild the canonical nine-root provider and all shims.
3. Run the complete compiler and non-coverage library gates.
4. Perform an independent adversarial review of the compiler relation, PEG
   result boundary, binary lengths, GC roots, optional-owner lifecycle, and
   raw-Lua allowlist.
5. Commit intentionally, push the current branch, refresh the PR summary with
   the API breaks/retained boundaries, and follow exact-head Linux,
   sanitizer, and Codecov checks. Do not dispatch the waived macOS workflow.

## 9. Test and validation matrix

### 9.1 Compiler-focused tests

Run from the repository root:

```sh
busted spec/lexer_spec.lua spec/parser_spec.lua spec/types_spec.lua
busted spec/checker/c_ffi_owned_types_spec.lua
busted spec/coder/c_ffi_owned_types_spec.lua
busted spec/checker/c_ffi_spec.lua
busted spec/coder/c_ffi_spec.lua
busted spec/checker/c_ffi_pointer_conversions_spec.lua
busted spec/coder/c_ffi_pointer_conversions_spec.lua
```

The new topical specs must cover syntax, invalid payloads, aliases, fields,
params/results, options, Arrays/Maps, export rejection, pointer qualifiers,
function tags, binary strings, all GC/FFI `void *` conversions, exactly-once
evaluation, and GC rooting. Keep pure checker cases out of the coder spec and
executable behavior out of the checker spec.

Because the compiler/type relation changes, the final local gate is
`make test`, not only the focused files.

### 9.2 PEG/relabel behavior

Required cases:

- zero captures;
- leading/interior/trailing nil captures;
- exactly 200 captures;
- the 201-capture public rejection;
- success tuple that resembles a failure triple;
- ordinary failure and explicit `throw("fail")` following the same search
  path;
- ordinary failure and `throw("fail")` behaving identically inside choice,
  repetition, and grammar recovery;
- empty, numeric-looking, and binary string labels;
- integer public labels rejected;
- callback errors and noncallable deferred failures;
- Lua closure, Lua C closure, and `__call` generic callability;
- Array grammar construction, recursion, duplicate rule rejection, size limit;
- Array definitions, duplicate rejection, invalid/unwritable names, and
  weak-cache collection;
- module-level `peg.match` leftmost/empty/capture/committed behavior;
- export inventory contains `match` and not `find`.

Run:

```sh
busted spec/stdlib/peg_spec.lua
busted spec/stdlib/peg_relabel_spec.lua
```

### 9.3 String/regex behavior

Required cases:

- strict numeric/string operand acceptance and removed Lua coercions;
- integral float `%q`/capture-index behavior;
- `%s`/`__tostring` and `%p` retained semantics;
- `%c` with byte zero through the specialized `snprintf` prefix conversion;
- exact owner casts with embedded/trailing NUL;
- all pack integer/float/string forms and binary output;
- regex cache identity/weak collection;
- unmatched/nested/200 regex groups and backreferences;
- malformed format/regex errors still leave the module usable.

Run:

```sh
busted spec/stdlib/string_spec.lua
busted spec/stdlib/string_regex_spec.lua
bash spec/support/ci_test_groups.sh library-peg-string
```

Library suites remain outside LuaCov.

### 9.4 UV ownership and lifetime

Run every affected focused suite, including:

- native owner/no-boxing;
- runtime/tasks/timers;
- filesystem;
- TCP/DNS/net facade;
- OS environment/signal/process;
- process stdio;
- delayed DNS and delayed FS callbacks;
- GC stress and cancellation/close paths.

Then run:

```sh
bash spec/support/ci_test_groups.sh libraries
```

The sanitizer CI gate must cover the final five-slot layout and owner
lifetimes. Do not weaken late callback transforms merely to make source anchors
easier to patch.

### 9.5 Provider, docs, and static bundle

Required final gates:

```sh
make stdlib
make test
git diff --check
```

Also run the focused `spec/libuv_build_spec.lua` export/source-inventory cases,
the source-rock vendored-source pack/unpack case, and production bundled/system
smokes affected by the stdlib source/type changes.

No new logical module, metadata key, shim, DSO, archive, or native payload is
introduced. Validate the same nine logical protocols and ten `luaopen_*`
entries in the combined provider.

## 10. Mechanical completion audits

Before final review, prove all of the following:

1. `rg 'peg\\.find|function find' titan/peg spec/stdlib/peg* doc/*/*peg*`
   finds no PEG API.
2. The PEG export inventory contains module-level `match` exactly once and no
   `find`.
3. `pattern_match_attempt` contains no `lua_pcallk`, argument pushes, raw result
   table creation, or stack-top arithmetic.
4. Removed PEG helpers have no references:
   `_raw_table_item`, `_encoded_name`, `_decoded_label`, `_field`, and
   `_require_function`.
5. Relabel/regex cache tables and metatables are constructed as typed Titan
   Maps; reads and writes are ordinary Map operations; raw Lua is confined to
   attaching the weak metatable.
6. `finish_string`, `checked_integer`, `checked_number`, `checked_string`,
   `value_is_integer`, and `regex_raw_table_item` are absent.
7. Exact owned buffers cast directly; every retained prefix conversion names
   and checks its logical length.
8. `rg 'lua_newuserdatauv' titan` finds only the custom coroutine allocation.
9. `rg 'ffi\\.lua_togco' titan/uv` is empty; ordinary UV owner allocators use
   the explicit GC-value pointer cast.
10. No UV owner record pairs a native pointer/owner with a redundant
   `storage: value`.
11. The native header, C trampoline, Titan record order, docs, and fixtures all
    say and implement five owner slots.
12. Every current Titan identifier named `owned` was renamed; occurrences are
    type syntax, prose, strings, Lua code, or intentional logical paths.
13. Generated `titan/peg/peg.c`, `titan/string/string.c`,
    `titan/uv/uv.c`, objects, providers, and shims are build products, not
    hand-edited source.
14. Contributor files still have only module-local top-level declarations;
    canonical PEG/string mains still own every public implementation.
15. `AGENTS.md` records the generalized owned-storage rule and the intentional
    raw-boundary exceptions.

## 11. Main risks and their required defenses

| Risk | Defense |
| --- | --- |
| Direct native match loses the 200th capture | Two fixed native results plus a 200-value flexible tail; exact 200-capture runtime test |
| Trailing nil captures shorten an Array | Retain the complete wrapper result with final non-nil position and explicit capture count |
| Explicit label `"fail"` accidentally remains committed | Test that it is deliberately identical to ordinary failure and that leftmost search advances |
| Array API breaks Lua-driven fixtures | Deliberately update fixtures through compiled Titan helpers; document the Titan Array signature |
| Owned keyword silently breaks existing source | Repository-wide token audit and rename before lexer change |
| Owned type permits invalid `sizeof` | Shared allocation eligibility, including a new direct-C-function rejection |
| Owned pointer adjustment drops const | Reuse qualifier inclusion and add typedef-qualified negative tests |
| Same-spelled module-local C function types share a native tag | Module-scope only C-bearing function tag keys; two-module value-call test |
| Character cast scans for NUL or loses trailing bytes | `luaS_newlstr` with exact `Udata.len`; embedded/trailing NUL tests |
| Temporary owner dies during string allocation | Materialize/root before `luaS_newlstr`; forced-GC test |
| A GC-derived pointer outlives its owner | Document that the cast does not root; UV publishes each owner record into its existing Runtime/control list before native use and clears it only after completion |
| `snprintf` whole-owner cast includes terminator or truncates `%c(0)` | Verify `actual == required`, copy into an exact owned array, and retain the `%c(0)` regression |
| Stream read exposes unused capacity | Separate `ByteChunk.length`; never whole-cast pending capacity |
| `uv_buf_t.base` outlives byte owner | `Buffer` retains both owned descriptor and `Bytes` |
| Optional handle cleared before native completion | Preserve current close/cleanup ordering and late-callback tests |
| Native callback reads shifted fields | Atomic five-slot header/C/Titan/fixture change plus sanitizer |
| Cleanup overreaches into custom userdata | Explicit coroutine exception and final `lua_newuserdatauv` audit |

## 12. Definition of done

This follow-up is complete only when:

- source-written owned types and binary character-array casts are implemented,
  documented in both manuals, and covered across checker/coder/runtime;
- statically GC-backed Titan values and all FFI pointer shapes explicitly cast
  to C `void *` through their underlying pointer with documented non-rooting
  lifetime semantics, and ordinary UV owner allocation uses that cast instead
  of Lua stack manipulation;
- PEG/string ordinary table/call/string operations use Titan facilities;
- the raw-Lua allowlist is narrow, explicit, and tested;
- `peg.find` is absent and `peg.match` is the documented/tested leftmost
  superset;
- string-only PEG labels fold `"fail"` into ordinary failure and preserve
  other binary labels;
- format/pack use Titan casts with updated public semantics;
- exact string builders no longer use `finish_string`;
- all ordinary stdlib native allocations use `.new()`/`.new_array()`;
- typed Titan Maps create both weak caches and metatables, with raw Lua limited
  to attaching those metatables;
- UV owners no longer duplicate pointer and storage, while logical-length and
  borrowed-lifetime records remain;
- the five-slot callback protocol is coherent in source, C, docs, transforms,
  and tests;
- the combined provider builds and the full local compiler/library gates pass;
- an adversarial review finds no missing caller, stale helper, lifetime
  regression, raw-stack escape, or documentation mismatch;
- the branch is pushed and exact-head Linux/sanitizer/Codecov evidence is
  green, with the macOS waiver recorded.

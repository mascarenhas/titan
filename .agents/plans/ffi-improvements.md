# Named C tags, host-validated C FFI, stack C objects, C operators, and shim reduction

Status: detailed implementation plan. This document specifies the complete
feature and migration; it is not an implementation patch.

## 1. Outcome

Make Titan's existing C FFI expressive enough that ordinary, public C APIs can
be used directly from Titan source without trivial cast, constant, storage, or
operator wrappers. The first production consumer is `titan.uv`.

The completed change provides:

1. Source-visible base names for named file-scope tag-only C structs and
   unions, without inventing typedefs or changing their canonical
   `struct T`/`union T` spelling.
2. Directional, host-validated C pointer conversions, including the unsafe
   object-pointer casts required by libuv's handle convention.
3. Zero-initialized automatic C structs, unions, and fixed-size C arrays in
   Titan functions.
4. Direct C arithmetic, comparison, and bitwise operations with C promotions
   and C run-time behavior.
5. Correct preprocessing and import of libuv's `UV_E*` enumerators and
   correctly typed unsigned object-like integer macros such as `UINT_MAX`.
6. A substantially smaller native libuv shim: Titan source calls public libuv
   directly wherever the only obstacle was a pointer cast, a C operator, a
   stack aggregate, a tag-only platform type, or an imported constant. This
   includes DNS submission, `addrinfo` normalization, TCP bind, and TCP connect
   submission while preserving the existing opaque address cell. Obsolete
   wrappers are physically removed under compiled-module ABI 0.18.
7. Titan-side coroutine transfer rooting through the public Lua uservalue API,
   while retaining only the native coroutine entry/tag boundary.
8. Complete checker, coder, library, packaging, sanitizer, Linux, and macOS
   evidence, plus matching language and implementation documentation.

Representative end-state source is:

```lua
local libuv = foreign import "uv.h"
local shim = foreign import "titan/uv.h"

local options: libuv.uv_process_options_t
local stdio: libuv.uv_stdio_container_t[3]
local hints: libuv.addrinfo

options.exit_cb = shim.titan_uvshim_process_exit_cb
options.stdio = stdio
options.stdio_count = 3
stdio[0].flags = libuv.UV_CREATE_PIPE | libuv.UV_READABLE_PIPE
hints.ai_family = libuv.AF_UNSPEC
hints.ai_socktype = libuv.SOCK_STREAM
hints.ai_protocol = libuv.IPPROTO_TCP

local status = libuv.uv_spawn(loop, process, options)
if status < 0 and status ~= libuv.UV_ECANCELED then
    -- ...
end

libuv.uv_close(tcp, shim.titan_uvshim_close_cb)
```

This is explicitly `titan.uv` internal dogfooding. Its callback symbols assume
the standard library's private owner layout and dispatcher protocol; they are
not a general callback API. User-facing documentation uses a neutral
host-provided C callback fixture and continues to state that Titan functions
cannot yet be adapted to C callback ABIs.

The source-level `uv_tcp_t *` to `uv_handle_t *` conversion in the last line is
unsafe. Titan emits an explicit `(uv_handle_t *)` cast after category and
qualifier checks and validates that exact construct with the configured C
compiler. Titan does not claim that the pointed-to structs are related,
layout-compatible, or share a prefix.

This plan supersedes the still-preliminary parts of
`.agents/plans/c-ffi-redesign.md` for the features described here. It builds on
the C type, aggregate, owned-storage, function-pointer, variadic-call, and
address-coercion support already present on `master`; it does not redesign
`foreign import` again.

## 2. Scope and non-goals

### 2.1 In scope

- C object-pointer conversion at assignments, local initialization, direct C
  calls, C function-pointer calls, returns, and other checker sites that
  currently require exact C type equality.
- Compiler probes generated in a temporary directory, compiled without linking
  or running target code, and cached for one `titanc` compilation session.
- Exact C declarator rendering shared by ordinary code generation and probes.
- Source-visible type-namespace aliases for named file-scope `struct` and
  `union` tags that lack a real same-name typedef, while preserving C's
  separate tag and ordinary identifier namespaces.
- One-dimensional source-written fixed C arrays, with imported nested or
  typedef array types continuing to work.
- Initializer-less, typed automatic C aggregate declarations with guaranteed
  zero initialization.
- C aggregate preservation across Titan `try`/`catch`/`finally` longjmp paths.
- C unary, arithmetic, relational, equality, bitwise, shift, and pointer
  operators described in section 6.
- Correct C preprocessor argument substitution around `#` and `##`.
- Direct use of imported enum and object-like macro constants.
- Moving every libuv wrapper made unnecessary by these facilities into the
  owning `titan/uv/*.titan` contributor, including DNS result traversal and
  the bind/connect path while retaining the normalized opaque address cells.
- Moving coroutine transfer-root set/clear logic to
  `titan/coroutine.titan` through `lua_setiuservalue`.
- Bumping the compiled-module ABI to 0.18, migrating every versioned runtime,
  loader, installer, test, and CI path, and preserving the separate 0.17 tree
  without trying to load it as compatible.

### 2.2 Deliberately out of scope

- Safe structural inheritance, common-initial-sequence inference, or layout
  proof between unrelated C structs. The new object-pointer path is explicitly
  unsafe.
- A general C expression evaluator inside the Titan compiler.
- Running probe executables. Probes are compile-only so cross-compilers remain
  supported.
- Variable-length arrays, zero-length compiler-extension arrays, inferred array
  extents, multidimensional source syntax in this iteration, compound literals,
  or heap allocation changes.
- Escape analysis for pointers to automatic storage. The programmer owns
  lifetime correctness after entering the FFI.
- Titan-function-to-C-callback adaptation. Libuv callback trampolines remain C.
- Replacement of the normalized opaque `titan_uvshim_address` representation,
  interpretation of platform `sockaddr` fields by `titan.uv`, exposure of those
  address types through the public `net` API, or removal of the cell's native
  compile-time size/alignment assertions. The general FFI necessarily exposes
  the complete tag types and their ordinary fields to source; this migration
  deliberately uses only pointer conversion and `sockaddr_storage.sizeof`.
- Explicit Titan syntax for selecting a C tag when a real same-name typedef
  already owns the base type name, and named enum-tag aliases while imported
  enums still lower to C `int`.
- C boolean short-circuit operators, C truthiness for `and`/`or`, C `sizeof`,
  arbitrary function-like C macros, or C preprocessor expressions at Titan run
  time.
- Reinterpreting Titan `//` or `^`: they remain Titan floor division and
  exponentiation.
- Purging the separately versioned 0.17 provider tree. The 0.18 installation
  replaces only the canonical generated Lua shims and owns a new
  `lib/titan/0.18` pair.

## 3. Design invariants

### 3.1 The C compiler validates C; the Titan checker owns Titan semantics

The configured compiler is authoritative for whether a generated C construct
is accepted by the selected headers, target, flags, and implementation. A probe
answers a narrow question such as:

- can this source expression be explicitly cast to that object-pointer type?
- can these already-selected operands form this C operator expression?
- does the exact declaration syntax compile under the active headers?

A successful probe does not:

- infer that two structs have an inheritance relation;
- infer an operator result type;
- override a Titan-specific GC, ownership, lifetime, or serialization rule;
- make function and object pointers interchangeable;
- permit qualifier loss;
- turn an arbitrary cast into implicit gradual compatibility.

The checker therefore performs hard category checks and computes the source
type/result first. The probe validates the exact C lowering second. The coder
then emits the already-validated lowering. Pure relations in
`titan-compiler/types.lua`, especially `types.compatible`, remain deterministic
and side-effect free; they must not invoke the filesystem or a compiler.

### 3.2 One effective toolchain

Probes use the same effective native configuration as generated modules:

- the argv-parsed `CC`, including configured command prefixes;
- `driver.CFLAGS`;
- `TITAN_EXTRA_CPPFLAGS`;
- `TITAN_EXTRA_CFLAGS`;
- the installed Lua and Titan include paths;
- the foreign import's ordered headers and resolved include context;
- the same C language mode selected for generated code.

They do not use `cc` by name, guess a host from `uname`, change warnings, link,
or execute a binary. `AR`, `RANLIB`, and link-only `TITAN_EXTRA_LIBS` are not
probe inputs. The profile and cache key include every effective input that can
change the compilation answer.

The probe layer first compiles a baseline translation unit containing the exact
ordered header preamble but no candidate expression. If that fails, the foreign
import/toolchain is broken and the checker reports the captured compiler
diagnostic as an infrastructure error. It must not misreport every candidate as
an incompatible type.

Use the same warning-clean external probe function declaration/definition in
the baseline and candidate; the baseline body contains only `(void)0`, while
the candidate substitutes the tested declaration/expression. This prevents
`-Wall -Werror` from turning an unused helper into a false negative.

Extract the driver's current parsed compile-argv construction into a shared
read-only toolchain descriptor used by both ordinary object compilation and
`cprobe`; do not independently split `driver.CFLAGS` or rebuild include lists
in the probe module. Extend `configure_foreign_c`/`cpp.new_context` with the
target-selecting compile flags needed for predefined-macro discovery while
keeping ordinary preprocessor-only flags distinct.

Titan's process execution is POSIX-only today and its existing driver/CPP paths
execute fully shell-quoted argv through `os.execute`/`io.popen`. Reuse and
extract that established mechanism rather than claiming a native argv runner
exists. The probe API remains an argv list; the shared runner shell-quotes every
argument, sets `LANG=C` and `LC_ALL=C`, captures diagnostics/status, and never
concatenates an unquoted compiler/header/flag/path value.

### 3.3 Preserve source evaluation order

Titan continues to evaluate operands and call arguments once, from left to
right. C-mode operators use the existing temporary-based
`ordered_binary_operands` lowering before applying the C operator. "C
semantics" governs conversions and the operation's value; it does not adopt C's
unspecified operand evaluation order.

### 3.4 Keep native ABI boundaries native

Plain C callbacks required by libuv remain native because Titan functions have
hidden `lua_State *`, module `Udata *`, and closure parameters. Compile-time
layout assertions, the dispatcher, the narrow POSIX `SIGPIPE` helper, minicoro's
entry function, and Lua-internal tag comparison also remain native.

Everything else moves only when Titan can express it using public C/Lua APIs
without a new alias header, identity trick, private-layout dependency, or
one-off lowering.

Ordinary runtime `assert(...)` calls inside a wrapper are defensive C-shim
checks, not part of the Titan or libuv behavioral contract. When a wrapper is
deleted, do not recreate those assertions as Titan branches. Rely on the
existing public Titan validation and control-flow invariants, and preserve only
observable error behavior, ownership, lifetime, ordering, and narrowing rules.
Compile-time layout assertions that remain beside a retained opaque native
representation may stay in C; Titan does not duplicate them.

## 4. Named C tags and host-validated C conversions

### 4.1 Source-visible names for tag-only structs and unions

The C parser already records most named composite tags under internal keys such
as `struct@addrinfo` and `union@Value`, but its best-effort `TypeList` may omit
a pure forward tag reached only through another declaration and may discard an
unsupported typedef altogether. Extend the registrar with explicit metadata
for every syntactically declared file-scope typedef name and every named
file-scope struct/union tag declaration or reference before best-effort type
conversion. Expose each eligible tag in that foreign module's Titan type
namespace through its base name when the complete parsed header closure has no
real same-name typedef:

```c
struct Item { int value; };
union Cell { int integer; double number; };
```

```lua
local c = foreign import "items.h"

local item: c.Item
local cell: c.Cell
```

This is a Titan namespace projection, not a C declaration. The module's
`type_members.Item` points directly at the existing canonical `Type.CStruct`
for `struct@Item`, and likewise for `Type.CUnion`. Do not construct
`Type.CTypedef("Item", ...)`, add a private alias header, emit a `typedef`, or
register bare `Item` in `symtab.foreign_types`/`foreign_names`. Exact
declarator generation continues to spell the types `struct Item` and
`union Cell`.

The registrar metadata is part of the `TypeList` contract: a
`typedef_names[name]` set records every syntactic file-scope typedef, and a
`file_scope_tags[name]` table records `struct`/`union`/`enum` kind, canonical
raw key, and declaration/definition provenance. C has one shared tag namespace
per scope: a same-scoped reuse with a different tag kind is a conflict, not two
alias candidates; enum entries participate in that conflict check even though
this iteration publishes no enum-tag alias. The registrar must create or retain
the raw canonical entry for file-scope references such as
`typedef struct Item ItemRef;` and `struct Item *item;`, but must not export a
tag introduced only in a function-prototype parameter or other non-file scope.
Do not derive eligibility by stripping `struct@`/`union@` from every surviving
map key.

The unqualified raw key is canonical only at file scope. Because
`cdriver.process_file` parses each imported header independently, the registrar
cannot decide whether a tag spelling in a prototype refers to a file-scope tag
made visible by an earlier foreign import. Give each prototype a stable scope
identity and preserve unresolved tag-reference metadata. During
`foreigntypes` conversion, resolve a reference against the checker's currently
visible module-wide file-scope tag registry first; only when no such tag exists
may it intern a prototype-local object under that scope identity. Repeated uses
within one prototype share that local object, while a later file-scope tag with
the same spelling is distinct. Scope resolution must therefore follow the
ordered foreign-import environment, not an isolated `TypeList`.

The checker/symbol table owns a module-wide file-scope tag registry keyed by
base name and carrying kind, canonical type, header, and provenance. A
same-kind declaration in a later import reuses/completes that type. A
different-kind struct/union/enum declaration is an explicit fatal diagnostic
with both provenances. Within one `TypeList`, the registrar reports the same
kind conflict as a fatal header error rather than counting it among
best-effort unsupported declarations.

Collect that complete metadata before publishing aliases. Pre-scan and reserve
every real typedef name even if its target is unsupported:

- `typedef struct Item Item` exposes the real `CTypedef`; no fallback alias is
  needed;
- `typedef int Item; struct Item { ... };` is legal because typedef and tag
  names occupy different C namespaces, and `c.Item` must mean the real typedef
  regardless of declaration order;
- `typedef struct Item ItemRef` still allows both `c.ItemRef` and the synthetic
  tag spelling `c.Item`;
- anonymous structs and unions receive no invented name;
- prototype-scope or block-scope tags receive no module alias;
- enum tags remain on the existing C-integer path and receive no alias in this
  iteration.

Retain `struct@T`/`union@T` as the canonical file-scope symtab keys. A
file-scope forward tag receives the source alias immediately; a later
file-scope definition completes that same `CStruct`/`CUnion` object in place.
Existing `_definition_order` and `foreign_definition_visible` rules remain
authoritative: pointers may name an incomplete tag, but field access,
allocation, `sizeof`/`alignof`, and automatic by-value storage require a
definition visible at the current declaration frontier. Do not clone a
file-scope composite per header, merge a prototype-scope tag into it, or let
later completion leak into an earlier module-variable initializer.

The current allocation and field paths already consult completeness, but
`c_pseudo_member` currently constructs `sizeof`/`alignof` without checker state.
Thread the state/frontier into pseudo-member resolution and reject
`sizeof`/`alignof` when the canonical tag is incomplete or its later definition
is not visible. A flexible-array-member struct remains complete for
`sizeof`/`alignof` even though its existing allocation restrictions remain.

Centralize the same frontier-aware **complete C object** check and apply it to
every Titan source sink that requires an object layout: by-value function
parameters/results, module variables, initialized and initializer-less locals,
by-value cast targets, fixed-array element types, allocation, pseudo-size
operations, and field access. Resolve typedefs and recurse through array
elements; a pointer to an incomplete struct/union remains legal. This closes
existing by-value paths as part of the tag feature instead of relying on the
generated C compiler to reject them later.

C tag names and ordinary identifiers are separate namespaces. Titan must
preserve legal headers such as:

```c
struct stat { /* ... */ };
int stat(const char *path, struct stat *out);
```

In type syntax, `c.stat` selects the tag alias. In expression syntax,
`CModule.members.stat` wins, so `c.stat(...)` continues to call the function;
only when no ordinary member exists may the same spelling become a
`Type.CTypeNamespace` for `.new`, `.new_array`, `.sizeof`, or `.alignof`.
When both namespaces contain the name, those expression pseudo-members are
intentionally unavailable through that collided spelling and produce a
specific diagnostic; a future explicit type-expression/tag syntax can address
that rare ambiguity. Do not use parent-sensitive guessing that could steal a
real field named `new` from an imported object.

This source alias is local to the module performing the foreign import. It is
not serialized in a Titan module interface and does not itself require a
compiled-module ABI bump.

### 4.2 Direction and terminology

All conversion questions preserve the checker's existing direction:
`expected` is the destination type and `found` is the source expression type.
Probe cache keys and diagnostics use that order.

Do not call libuv's convention "handle inheritance" in normative
documentation. In C, `uv_tcp_t *` is not implicitly compatible with
`uv_handle_t *`; libuv's public API expects an explicit cast. Titan calls this
an **unsafe object-pointer conversion**.

### 4.3 Conversion ladder

For an expression being adjusted to a destination, apply this ladder in order:

1. Existing Titan-specific conversions:
   `value`/`TValue`/`Udata`, owned C storage, string/character pointers, nil,
   boolean, Titan numeric boundaries, and exact local-address anchoring.
2. Exact C type equality, typedef resolution, qualifier-preserving compatible
   pointers, array decay, and the existing object-pointer/`void *` rules.
3. Exact mutable or const address conversion of a local C object. A struct or
   union local lowers as `&local`; an array local decays and never becomes
   `&array`.
4. Unsafe object-pointer conversion:
   both resolved sides must be C pointers to object types; the conversion must
   not discard `const` or `volatile`; neither pointee may be a function type;
   and the exact explicit cast must pass the session probe.
5. Otherwise reject with a directional diagnostic.

The two last C steps compose for a local aggregate: if a local `T` is supplied
where `U *` is expected, first form the tracked address and then validate/emit
the unsafe object-pointer cast, recording
`kind = "address_then_unsafe_object_pointer"`. The generated expression is
`(U *)&local`, and the local is marked address-taken/mutated exactly as it is for
an exact mutable `T *` argument.

The unsafe fallback may accept unrelated complete or incomplete object types,
because an explicit C object-pointer cast normally does. That breadth is the
declared FFI trust boundary, not an accidental consequence hidden inside
`types.compatible`.

Function pointers remain exact/compatible according to their existing
signature rules. No fallback crosses object/function-pointer categories.
Integer/pointer conversions require an explicit source cast and are not added
to implicit adjustment. Qualifier removal remains an explicit error even if a
particular compiler would accept it with a warning.

Qualifier preservation is recursive across corresponding pointer levels; it
must reject holes such as `const T ** -> T **`, not only inspect the outer
`CPointer`. `const` and `volatile` may be added but not removed. `restrict`
remains a declaration/lvalue promise rather than a value-conversion
qualification: preserve it when rendering the original declaration, do not add
it to a synthesized cast, and do not use its presence alone to reject an
otherwise valid pointer value conversion.

### 4.4 Probe shape

The unsafe pointer probe uses the exact shared declarator renderer and an
explicit cast, for example:

```c
#include <uv.h>
extern uv_tcp_t *titan_probe_source;
void titan_probe(void);
void titan_probe(void) {
    uv_handle_t *titan_probe_target =
        (uv_handle_t *)titan_probe_source;
    (void)titan_probe_target;
}
```

This validates only that the construct Titan will emit is compilable under the
active toolchain. It does not validate representation, alignment, common
prefixes, or usable layout; most category-safe explicit object-pointer casts
will intentionally compile. An uncast assignment is not the right probe for
libuv: conforming compilers diagnose it, and accepting a warning would not
establish compatibility. Probe sources use `extern` operands so
uninitialized-value warnings cannot influence the answer.

### 4.5 Checker integration

Introduce a checker-context conversion helper rather than widening
`types.compatible`:

```lua
adjust_c_expression(module_probe, source_node, expected_type, use)
    -> adjusted_node | diagnostic
```

The helper may attach an `Ast.ExpCast` with:

```lua
node._implicit_coercion = true
node._c_conversion = {
    kind = "unsafe_object_pointer",
    source = resolved_source,
    target = resolved_target,
    probe_key = key,
}
```

Audit every directional adjustment path, not only direct positional calls:

- local and multi-local declarations;
- assignments and returns;
- fixed direct foreign calls and named foreign calls;
- foreign function-pointer calls;
- fixed-prefix and explicit typed C variadic arguments;
- synthesized omitted/nil arguments;
- C struct/union field assignments;
- comparison/operator operand adjustment;
- callable compatibility slots where a value is actually converted.

Structural Titan function compatibility must stay pure. A successful conversion
at one call site does not rewrite global function type equality.

`checkmatch` currently forces resolved C equality, while `trycoerce` contains
the existing local-address special case. Consolidate C expression adjustment
around `trycoerce`/the new contextual helper so the check and the AST cast
cannot disagree.

### 4.6 Diagnostics

Diagnostics distinguish:

- C tag-kind conflict, naming both declarations/headers;
- incomplete or not-yet-visible C object use, naming the by-value/layout sink;
- category rejection:
  `cannot convert object pointer 'A *' to function pointer 'B *'`;
- qualifier rejection:
  `unsafe C conversion from 'const A *' to 'A *' would discard const`;
- host rejection:
  `configured C compiler rejected conversion from 'A *' to 'B *'`;
- probe infrastructure failure:
  `cannot validate C conversion because the foreign header baseline failed` or
  because the configured compiler/toolchain could not be started.

Normal errors show a concise first compiler line. `-v` prints the exact probe
command, temporary source, cache hit/miss, exit status, and complete captured
diagnostic. Expected rejected candidates are not written directly to the
terminal during an ordinary compile.

## 5. Automatic C objects and fixed arrays

### 5.1 Surface syntax

Permit a local declaration with an explicit C aggregate type and no `=`:

```lua
local options: libuv.uv_process_options_t
local storage: libuv.uv_stdio_container_t[3]
```

It is a declaration of one zero-initialized automatic C object. The generated
C is:

```c
uv_process_options_t options = {0};
uv_stdio_container_t storage[3] = {0};
```

This form is narrowly legal for:

- a complete C struct;
- a complete C union;
- a fixed C array whose recursively resolved element type is complete and whose
  extent is a positive compile-time integer literal.

It is rejected when the declared top-level type is a Titan type, C scalar, C
pointer, function, `void`, incomplete struct/union, flexible-array-member
struct, or unsized array, and for zero/negative extents or multiple declarations
in one no-RHS statement. A fixed array may contain complete C scalar, pointer,
struct, union, or nested imported-array elements. A standalone scalar/pointer
local continues to require an initializer.

The first iteration accepts one source-written postfix extent only in the
single initializer-less automatic-local form:

```lua
local one_dimension: H.item_t[8]
```

Add an `Ast.TypeCArray(base, length)` node through a dedicated stack-local type
production; `typefromnode` constructs `Type.CArray` only while checking that
declaration. Source-written `T[N]` is rejected in parameters, returns, type
aliases, record fields, casts, module variables, ordinary initialized locals,
nullable/postfix combinations, and every other general type position. Imported
typedefs and headers may still describe nested arrays wherever the existing FFI
already permits their types. This does not add fixed Titan arrays.

Using declaration syntax, rather than pseudo-functions such as `.stack()` and
`.stack_array(n)`, is intentional. A C array is not a first-class assignable or
returnable expression; disguising a declaration as a call would require
parent-sensitive exceptions throughout result adjustment and code generation.

### 5.2 Value and address behavior

- A struct or union local is an lvalue C object.
- A fixed array local is an lvalue C array and `#array` yields its fixed extent.
- `array[index]` keeps the existing zero-based C indexing rules.
- A struct/union local passed to `T *` uses the existing implicit address
  conversion and emits `&local`.
- An array passed or assigned to `element *` uses C decay and emits `array`, not
  `&array`.
- Whole struct/union assignment uses C copy semantics.
- Whole-array assignment, return, capture, and value-copy are rejected.
- A local pointer may hold the resulting address/decay and may itself be
  returned or captured. Titan performs no escape analysis; using it after the
  automatic object's C block ends is unsafe programmer responsibility.
- Capturing the aggregate object itself is rejected. Boxing would change its
  address and the current closure representation cannot carry a read-only raw
  C aggregate by value.

An automatic aggregate containing pointers or other C storage receives no
recursive lifetime management. A pointer retained by C can dangle after the
block. A C aggregate containing GC-bearing internal Lua fields is also not
recursively traced. Reject automatic structs/unions/arrays that transitively
contain `TValue`, `Udata *`, or another compiler-recognized GC-bearing FFI
field. Existing standalone `TValue`/`Udata *` special conversions retain their
current stack anchors.

### 5.3 Exact C declarators

Extract `foreignctype`/`foreigncdecl` from `titan-compiler/coder.lua` into a
pure shared module, `titan-compiler/cdeclarator.lua`, with at least:

```lua
render_type_name(type)              -- cast/expression type
render_declaration(type, name)      -- named object/function declaration
adjust_parameter_type(type)         -- C array/function parameter adjustment
```

It must recursively render:

- pointers and pointee qualifiers;
- direct arrays, including nested imported arrays;
- pointers to arrays;
- function types and function pointers;
- structs/unions through their legal tag or typedef spelling;
- typedef names without unnecessarily expanding their declarator.

`render_type_name` handles abstract pointer-to-array and pointer-to-function
names needed by casts/probes, but rejects a raw array as a cast target.
`render_declaration` alone owns direct array objects.

For example:

```c
T x[3];
T (*p)[3];
int (*cb)(uv_handle_t *, int);
```

`Type.CArray(T, 3)` must never fall through to the current `T *` spelling in a
declaration. Both ordinary codegen and probe generation use this module, so the
probe cannot validate different syntax from the final translation unit.

### 5.4 `try`/longjmp correctness

C automatic variables modified after `setjmp` are indeterminate after
`longjmp` unless their values are preserved through volatile storage. The
current spill machinery is scalar-oriented, field/index writes do not identify
their aggregate root, and C arrays cannot use an assignment-based spill.
Automatic aggregates are not complete until this is fixed.

Extend try-spill analysis and lowering as follows:

1. Trace a C lvalue through `VarDot` and C index nodes to its root `Ast.Decl`.
2. Mark the root written after whole-object assignment, field assignment, array
   element assignment, and any foreign call receiving its mutable address.
3. For a non-GC automatic C aggregate that crosses a longjmp boundary, declare
   a volatile byte spill:

   ```c
   volatile unsigned char spill[sizeof local];
   ```

4. Copy object-representation bytes to the spill after zero initialization and
   after each tracked write/mutable call.
5. Reload object-representation bytes on the existing longjmp recovery path.
6. Use explicit byte loops with volatile accesses. Do not cast volatile away
   and call `memcpy`.
7. Preserve the existing scalar and Lua-stack GC spill paths unchanged.

The analysis is intentionally conservative. A raw pointer alias mutated later
or asynchronously by C remains outside Titan's proof and is unsafe. If the
complete aggregate spill cannot be implemented in the same change, the checker
must reject any automatic aggregate marked as crossing a try boundary; silently
emitting indeterminate C reads is not an acceptable partial implementation.

The spill is the last normally completed state. A mutable foreign call commits
its new representation only when it returns and the post-call copy completes.
If arbitrary C mutates through the pointer and then itself nonlocally exits,
Titan does not promise to preserve the partial mutation or the state observed
through external aliases. Recovery reloads the last committed pre-call spill
before Titan reads the local, but only direct Titan writes and mutable foreign
calls that return normally belong to the tracked-state guarantee.

## 6. C operator mode

### 6.1 Activation

An operator enters C mode when at least one operand is a C scalar, C pointer, or
C array and the operator appears in the supported matrix below. `COwned` is a
Titan userdata wrapper, not a C operand; it must first be adjusted to its
payload pointer.

If no operand is a C type, existing Titan semantics and result types are
unchanged.

The checker attaches a complete trait:

```lua
node._c_operator = {
    cop = "!=",
    lhs_target = ...,
    rhs_target = ...,
    lhs_decay = false,
    rhs_decay = false,
    result = ...,
    probe_key = ...,
}
```

The coder consumes the trait and never recomputes compatibility or promotions.

### 6.2 Supported operators and results

| Titan syntax | Accepted C-mode operands | Result |
| --- | --- | --- |
| unary `-x` | C integer or C float | integer-promoted type or original float type |
| unary `~x` | C integer | integer-promoted type |
| `a + b` | arithmetic pair; complete object pointer/array plus integer | usual arithmetic result or resolved pointer |
| `a - b` | arithmetic pair; pointer/array minus integer; qualification-compatible complete object pointers | usual arithmetic result, resolved pointer, or Titan `integer` for pointer difference |
| `a * b`, `a / b` | arithmetic pair | usual arithmetic result |
| `a % b` | C integer pair | usual arithmetic result |
| `<`, `<=`, `>`, `>=` | arithmetic pair or qualification-compatible object-pointer pair | Titan `boolean` |
| `==`, `~=` | arithmetic pair; object-pointer pair; pointer and `nil`; matching function pointers | Titan `boolean` |
| `a & b`, `a \| b`, binary `a ~ b` | C integer pair | usual arithmetic result |
| `a << b`, `a >> b` | C integer pair | integer-promoted left type |

Mappings are direct except:

- Titan `~=` emits C `!=`;
- binary Titan `~` emits C `^`.

Arrays decay to `CPointer(element)` before trait calculation and before operand
temporary selection.

For a binary pointer operation, select a symmetric deterministic common
expression type. Apply exact/qualification-compatible C composite rules first.
For equality between otherwise unrelated object pointers, convert both operands
to a `void *` type carrying the union of their reachable `const`/`volatile`
qualifiers. Do not use the unsafe unrelated-pointer fallback for ordering,
subtraction, or pointer arithmetic. Pointer subtraction requires compatible,
complete, non-void pointees, so its units cannot change with AST orientation.

Explicit exclusions:

- Titan `//` remains floor division;
- Titan `^` remains exponentiation, not C xor;
- `and`, `or`, `not`, concatenation, and current `#` semantics stay Titan
  operations;
- floating remainder;
- aggregate arithmetic/equality;
- pointer multiplication, division, modulo, bitwise operations, or shifts;
- arithmetic on `void *`, function pointers, or pointers to incomplete objects;
- relational function-pointer comparison;
- direct operators on a C bit-field expression; its declared width can change
  integer promotion, so the programmer must first cast it to an ordinary C or
  Titan integer type.

Unsupported C operands require an explicit cast to a Titan or supported C type;
they must not silently enter a Titan numeric helper path.

### 6.3 Mixed Titan/C operands

Mixed operands participate through their real generated C representations:

- Titan `integer` contributes the configured `lua_Integer` type recovered from
  the prefix's `luaconf.h`;
- Titan `float` contributes the configured `lua_Number` type;
- the ordinary integer promotions and usual arithmetic conversions then choose
  the common type exactly as C would for those operands;
- a C object pointer/array plus or minus Titan `integer` uses `lua_Integer` as
  the offset type and lets the probe validate the exact expression;
- C pointer equality with Titan `nil` lowers nil as a target-typed null pointer
  constant;
- other pointer/integer comparisons are rejected.

Do not pre-narrow a Titan operand to the other operand's C type. For example,
`unsigned char + Titan integer` promotes the `unsigned char` and combines it
with `lua_Integer`; `length > UINT_MAX` does not first wrap `length` to
`unsigned int`. The result still follows the actual target's ordinary C rules,
including conversion to an unsigned type when that is what the configured
`lua_Integer`/C operand ranks and ranges require.

This makes `status < 0`, `flags | mask`, `size - 1`, and mixed C floating
arithmetic ergonomic without inventing a source-only conversion rule.

### 6.4 Promotions and result typing

Compile success cannot tell Titan the expression's C type. Implement a pure
`titan-compiler/csemantics.lua` helper that performs:

- integer promotions;
- usual arithmetic conversions;
- float precedence (`long double`, `double`, `float`);
- signed/unsigned rank and representability rules;
- promoted-left result for shifts;
- pointer/array decay and pointer-result rules.

Arithmetic drops typedef identity and returns the canonical resolved primitive
C type. Imported enums already lower to C `int`. Pointer subtraction executes
as C pointer subtraction and converts its result to Titan `integer`; do not
invent an inaccessible source-level `ptrdiff_t` type.

Populate `Type.CInteger(spelling, signed, rank, bits)` storage width from the
service toolchain profile, and keep the corresponding value precision/minimum/
maximum in that profile for conversion decisions. Query predefined macros
using the full target-selecting
`driver.CFLAGS` and `TITAN_EXTRA_CFLAGS`, not only CPP flags; `-m32`, `-arch`,
and cross-target options must describe the same target as generated objects.
Use `__CHAR_BIT__`, `__SIZEOF_*__`, `__CHAR_UNSIGNED__`, and signed/unsigned
maximum macros such as `__INT_MAX__`, `__UINT_MAX__`, `__LONG_MAX__`, and their
counterparts to establish value precision and representability even on targets
with padding bits. Do not assume plain `char` is signed or that `long` has host
widths. A compile-only assertion fallback may establish a missing target trait,
but no target program runs. An extension integer with unknown rank/precision is
rejected for result inference with a diagnostic requiring an explicit cast.

The same profile resolves `lua_Integer` and `lua_Number` from the configured
prefix's actual `luaconf.h`; never assume they are host Lua's defaults.

### 6.5 Probe and code generation

After category checking and result calculation, validate the exact expression:

```c
extern L titan_probe_lhs;
extern R titan_probe_rhs;
void titan_probe(void);
void titan_probe(void) {
    (void)(titan_probe_lhs OP titan_probe_rhs);
}
```

The probe includes the casts recorded in `lhs_target`/`rhs_target`. Pointer
subtraction and comparison probes therefore validate the actual selected
pointer conversions. The compilation service caches both acceptance and
rejection.

The C-trait branch runs before all Titan-special branches in
`codeunaryop`/`codebinaryop`. It emits:

- no `intop` wrap;
- no Lua floor-division or modulo correction;
- no normalized Lua shifts;
- no `pow`;
- no Titan numeric comparator helper;
- no Titan divide-by-zero guard.

C integer division truncation, remainder sign, unsigned conversion and wrap,
signed overflow, division by zero, invalid shifts, and implementation-defined
right shift retain C behavior or C undefined behavior. The language manual must
say this directly.

## 7. C constants and preprocessing

### 7.1 `UV_E*` is a token-paste bug, not an enum-import feature

The C parser already recognizes enums, `c-parser/ctypes.lua` publishes ordinary
enumerator names, and `titan-compiler/foreigntypes.lua` maps enumerators to C
`int`. Ordinary values such as `UV_RUN_DEFAULT` and `UV_FS_O_RDONLY` already
reach Titan.

Libuv builds `uv_errno_t` with an X-macro whose replacement contains
`UV_ ## code`. The current `replace_args` in `c-parser/cpp.lua` expands the
argument before noticing that it is adjacent to `##`; a system macro such as
`EIO` becomes its numeric value and Titan pastes `UV_5` instead of `UV_EIO`.
Fix preprocessing rather than adding libuv-specific constants or a new enum
path.

### 7.2 Required macro-substitution algorithm

For every function-like macro invocation:

1. Retain the raw argument token sequence.
2. Independently prescan an expanded copy for ordinary parameter use.
3. For `# parameter`, stringify the raw sequence.
4. For a parameter immediately adjacent to either side of `##`, substitute the
   raw sequence; use an internal placemarker for an empty argument.
5. For ordinary occurrences, substitute the prescanned copy.
6. Complete all left-to-right token pastes, reject a paste that does not form a
   valid preprocessing token, and remove placemarkers.
7. Rescan the completed replacement list under the existing macro-recursion
   suppression rules.

Do not mutate the shared raw argument vector: the same parameter may occur once
beside `##` and once ordinarily. Preserve source locations sufficiently for a
bad paste diagnostic to point at the invocation.

Regression coverage includes:

- macro-valued arguments stringized without expansion;
- one-level paste versus the two-level helper pattern that expands before
  pasting;
- empty left/right arguments and chained paste;
- recursive/self-referential macro guards;
- a minimal libuv-shaped `UV_ERRNO_MAP(XX)`;
- real pinned `uv.h` import of `uv_errno_t`, `UV_EIO`, `UV_EOF`,
  `UV_ECANCELED`, and other currently shimmed errors.

### 7.3 Object-like integer macros

`c-parser/cdefines.lua` currently recognizes rank suffixes but loses unsigned
suffix semantics. Preserve the parsed object-macro expression and each integer
token's base/rank/unsigned candidate metadata; after the configured target
profile exists, make classification follow base, rank suffix, `U` suffix, and
usual conversions across compound expressions. `UINT_MAX` must import as an
unsigned C integer of the appropriate rank rather than signed `int`.

This is a bounded constant-import fix, not a complete implementation of C's
integer-constant typing algorithm. Cover decimal, octal, and hexadecimal
spellings with `U`, `L`, `UL`, `LL`, and `ULL`, including values whose first
representable type depends on base. Feed the resulting type through the
toolchain arithmetic profile when the target width matters.

Before deleting `titan_uvshim_buf_max_length`, prove that direct
`limits.UINT_MAX` has the correct C type and value on Linux and macOS and that
the existing Titan bound check does not narrow it before comparison.

## 8. Probe-session architecture

### 8.1 Modules and ownership

Add:

- `titan-compiler/cdeclarator.lua`: pure exact C declarator rendering;
- `titan-compiler/csemantics.lua`: pure C categories, promotions, and result
  typing;
- `titan-compiler/cprobe.lua`: toolchain profile, temporary translation units,
  process execution, diagnostics, and session caches.

Add each module to the explicit Lua module table in
`titan-dev-1.rockspec`. The Makefile's compiler-source wildcard will see the new
files, but verify that stdlib completion stamps and installed-compiler
dependencies also invalidate correctly.

The resolver/driver owns one lazy `cprobe.Service` for the entire public
`titanc` invocation, including all source dependencies. It owns the toolchain
profile, runner, baseline/result caches, and cleanup. Each checked source module
gets a `cprobe.ModuleContext` containing its source directory and the exact
ordered include descriptors collected during that module's foreign-import
pass. Candidate checks begin only after that pass, so probes never borrow a
different module's header preamble.

Extend `checker.check` with an optional options/context argument. The
`defaultloader`, `tableloader`, filesystem child compilers, and direct driver
entry points thread the resolver service through it. A direct external
`checker.check` call without a service lazily creates and closes a fresh service
from the current configured foreign-C options; tests may inject a fake. There
is no contradictory "missing session" mode. Do not use a process-global result
cache that can survive `driver.configure_foreign_c`.

`titanc` creates the resolver service after parsing `-v`, passes verbose state
before the first checker call, and closes it on success, type error, codegen
error, and interrupted/exceptional exits.

### 8.2 Service and cache state

One service contains:

```lua
{
    compiler_argv = ...,
    language_mode = ...,
    cppflags = ...,
    cflags = ...,
    include_dirs = ...,
    profile = ...,
    baseline_cache = ...,
    result_cache = ...,
    verbose = ...,
}
```

The service profile is derived once per effective toolchain. The baseline cache is
keyed by ordered include descriptors and source/include context. The result
cache key includes:

- probe kind and direction;
- exact rendered source/destination declarations;
- operator spelling and operand conversions where applicable;
- ordered foreign header preamble;
- language mode;
- complete compiler argv and effective compile flags;
- include roots or resolved quote-header paths;
- arithmetic-profile identity.

Cache both successful and rejected probes. A baseline infrastructure failure is
cached separately from a valid negative candidate.

### 8.3 Header fidelity

Use the include descriptors already returned by `cdriver.process_file`.
Angle imports preserve their generated angle spelling. Quote imports whose
meaning depends on the Titan source directory must either:

- use a resolved absolute quote spelling in the temporary probe; or
- recreate the exact source-relative include root.

Do not emit the original relative spelling from an unrelated `/tmp` directory.
The probe's ordered preamble must match generated C, including duplicate header
suppression behavior and any Titan runtime headers needed by imported special
types.

### 8.4 Temporary files and execution

Create one private directory with `mkdtemp` semantics below the OS temp root.
Give each probe deterministic, collision-free `.c`, optional `.o`, and captured
diagnostic paths within it. Compile with a non-linking mode supported by the
configured compiler (`-fsyntax-only` when established by the service, otherwise
`-c` to a private object). Delete candidate artifacts after each probe and the
directory on every normal/error exit.

Add a shared captured-command helper around the repo's established safely
quoted POSIX-shell execution. It accepts parsed argv only, quotes every element
with `cdriver.shell_quote`, applies the fixed C locale, and captures
stdout/stderr plus exit status. No raw configured string is interpolated.
Failure to start or an interrupted compiler becomes an infrastructure
diagnostic, not ordinary incompatibility. A future neutral native process API
can replace this helper without changing `cprobe.Service`.

Always clean the private directory. In verbose mode print the exact command,
complete candidate source, and captured diagnostic before cleanup. Tests inject
the runner and temp-root provider so cache, cleanup, command assembly, and
diagnostics do not depend on a real compiler. A small real-compiler integration
test proves the complete path.

## 9. Current implementation seams

The implementation should extend these existing paths rather than introduce a
parallel FFI:

- `titan-compiler/checker.lua`
  - global `foreign_c_options` and `configure_foreign_c`;
  - foreign-import `type_members`, `Ast.TypeQualName`, and C-module
    expression lookup for tag/ordinary namespace separation;
  - `checkmatch`'s current exact-C special case;
  - `trycoerce`, `is_mutable_c_address_source`, and
    `mark_mutable_c_address_source`;
  - foreign imports through `cdriver.process_file`;
  - `Ast.ExpUnop` and `Ast.ExpBinop` checking;
  - local capture/address validation and C field/index checking.
- `titan-compiler/types.lua`
  - `Type.CInteger`, `CFloat`, `CPointer`, `CArray`, `CFunction`,
    `CStruct`, `CUnion`, `CTypedef`, and `COwned`;
  - `c_pointer_compatible`, `c_address_coerceable`, and
    `c_mutable_address_coerceable`;
  - pure `coerceable`, `explicitly_coerceable`, and `compatible` relations.
- `titan-compiler/foreigntypes.lua`
  - primitive rank/signedness inventory;
  - C array conversion;
  - enum-to-C-int conversion;
  - canonical `struct@`/`union@` completion, typedef spelling, and
    struct/union completeness/FAM metadata.
- `titan-compiler/symtab.lua`
  - ordered global foreign type/name registries, extended with the module-wide
    file-scope C tag registry and provenance-bearing kind conflicts.
- `titan-compiler/coder.lua`
  - local `foreignctype`/`foreigncdecl`;
  - `newforeigntmp`, `codeforeignexp`, `codeforeigncall`, and C casts;
  - `ordered_binary_operands`, `codeunaryop`, and `codebinaryop`;
  - `collect_lvalue_write`, try-spill analysis, spill update/reload;
  - `Ast.StatDecl` lowering, which currently assumes an adjusted RHS.
- `titan-compiler/parser.lua`
  - local statements currently require `=`;
  - type grammar currently has no source-written C array postfix.
- `c-parser/cpp.lua`
  - `replace_args` eagerly expands arguments before `#`/`##` handling.
- `c-parser/cdefines.lua`
  - object-like integer literal inference records rank but not unsignedness.
- `c-parser/ctypes.lua`
  - raw named-tag registration under `struct@T`/`union@T`, distinct from
    ordinary typedef names;
  - pre-conversion file-scope tag/provenance metadata and the complete
    syntactic typedef-name set.
- `titan-compiler/driver.lua`
  - effective C configuration and checker configuration;
  - one resolver context across the source graph.
- `titan-dev-1.rockspec`
  - explicit installed compiler-module inventory.

Existing behavior that must not regress:

- C struct locals initialized from by-value C expressions;
- exact const and mutable local-address coercions and their TValue anchoring;
- C arrays imported from headers and counted `COwned` arrays;
- direct and named fixed foreign calls;
- typed C variadic calls;
- C function pointer calls;
- C field/union/index reads and assignments;
- `value`/`TValue`/`Udata` bridges and GC anchors;
- generated quote/angle foreign includes;
- left-to-right calls and binary operands.

## 10. Native shim end state

### 10.1 Permanently native libuv boundary

Keep in `titan-runtime/titan_uv.c`:

1. Static ABI/layout assertions, including owner slots, integer widths, and the
   opaque address cell's `sockaddr_storage` size/alignment.
2. The owner dispatcher.
3. Every plain-C libuv callback trampoline:
   signal, process exit, DNS, connect, write, shutdown, allocation, read,
   connection, timer, close, and filesystem.
4. `titan_uvshim_ignore_sigpipe_if_default`, which preserves an inherited signal
   disposition and changes only `SIG_DFL`.

Callbacks that are currently `static` but become direct Titan arguments must be
externally visible and declared in `titan-runtime/titan/uv.h`. Timer and
filesystem callbacks are already public; expose only the additional callback
symbols needed by migrated source. The DNS migration specifically promotes
`titan_uvshim_getaddrinfo_cb` and `titan_uvshim_connect_cb`; the private header
forward-declares `struct addrinfo` when `uv.h` has not already done so. This is
additive native ABI.

### 10.2 Move immediately after pointer conversion

Replace cast-only wrappers with direct public libuv calls in the owning
contributors:

- getaddrinfo cancel and addrinfo free;
- TCP init, close, listen, accept, read start/stop, write, and shutdown;
- every pipe init/read/write/close wrapper;
- process close;
- timer set-data, closing check, and close;
- filesystem set-data and cancel;
- signal init, oneshot start, and close.

Each replacement must preserve:

- owner `.data` installation before an operation can callback;
- the same callback trampoline;
- the same synchronous failure cleanup;
- integer normalization only at a Titan public API boundary;
- exact operation labels used in errors.

Do not mechanically remove every `as integer`. Remove casts whose sole purpose
was selecting Titan numeric/comparison operators. Retain conversions that
deliberately normalize a C width/signedness into a Titan `integer` return,
record field, index, or public error payload.

### 10.3 Move after constants, operators, and stack aggregates

Move these complete implementations to Titan:

- `titan_uvshim_process_spawn`;
- error-code getter functions;
- signal name/number mapping;
- buffer initialization, slice, copy, find, and text-copy helpers;
- stat extraction and file-kind classification;
- buffer maximum length.

Distribute private Titan helpers among `titan/uv/runtime.titan`,
`process.titan`, `file.titan`, `tcp.titan`, and `os.titan` according to
ownership. Do not recreate a monolithic Titan shim module.

Process-spawn acceptance invariants are:

- `uv_process_options_t` and all three `uv_stdio_container_t` elements are
  fully zero-initialized;
- stdin/stdout/stderr flags retain child-perspective pipe directions;
- argv strings and the pointer array stay rooted for the complete synchronous
  `uv_spawn` call;
- the native process-exit callback remains the `exit_cb`;
- process owner data is installed after `uv_spawn` even when it returns a
  synchronous error, matching current cleanup ownership;
- metadata unconditionally transitions to `PROCESS_SPAWNED` after every
  attempted `uv_spawn`, including a negative return, so the failure path closes
  the initialized process handle rather than discarding its storage;
- every partial pipe initialization follows the existing close/retire path;
- the missing-executable failure followed by a successful spawn remains a
  regression test, with generated-order assertions around spawn/data/state.

Signal mapping imports platform `SIG*` object constants from `signal.h`; never
hardcode Linux signal numbers. `SIG_DFL`/`SIG_IGN` behavior stays in the native
helper.

Buffer initialization casts the existing opaque destination to
`*libuv.uv_buf_t` and writes its public `.base` and `.len` fields after the
existing public Titan boundary has validated the operation. This uses existing
C pointer-field lvalues and does not require a new unary
pointer-dereference/whole-pointee assignment merely to reproduce
`*uvbuf = uv_buf_init(...)`. Add one ordinary
`local cstring = foreign import "string.h"` in the canonical `uv.titan` main;
the combined folder namespace lets the owning contributors call
`cstring.memcpy` and `cstring.memcmp` with C pointer
arithmetic/comparisons. Do not assume `uv.h` transitively declares those
functions.

Do not turn the C helpers' defensive `assert(...)` predicates into duplicate
Titan checks. The owning Titan APIs already establish nonnegative/in-bounds
offsets and lengths, live storage, and the `UV_BUF_MAX` limit before reaching
these helpers. Preserve the operational branches that affect valid behavior:

- zero-length copies do not call `memcpy` or perform invalid pointer
  arithmetic;
- an empty needle returns zero and a longer needle returns `-1` before
  `haystack_length - needle_length`;
- text allocation includes the terminator and always writes its terminating
  NUL;
- conversions to `size_t`/`unsigned int` occur only after the existing owning
  control flow has established that the value fits.

Use imported `UINT_MAX` for `UV_BUF_MAX`. If another target-width relation is
needed to justify a lowering, establish it once from the configured C profile
or a compile-only assertion; do not reproduce each deleted runtime assertion
as source validation.

Stat extraction uses public `uv_stat_t` and object-like `S_IFMT`, `S_IFREG`,
`S_IFDIR`, and `S_IFLNK`; it does not depend on unimported function-like
`S_IS*` macros. On Linux those names require the production `-D_GNU_SOURCE`
feature-test configuration under strict C99. Import/probe them under the exact
bundled and system CPP/C flags and on macOS; if the foreign-import context does
not expose them in any supported mode, retain stat classification natively
rather than adding private constants.

### 10.4 Move DNS/address normalization without changing its representation

The supported `uv.h` closure exposes complete named tags for
`struct addrinfo`, `struct sockaddr`, and `struct sockaddr_storage`; on Linux
they require the same production feature-test flags already carried through the
foreign-import context. Section 4.1 makes them source-nameable as
`libuv.addrinfo`, `libuv.sockaddr`, and `libuv.sockaddr_storage`. The obstacle
was source naming, not C completeness.

Delete the following C helpers and their public prototypes after their Titan
callers have landed:

- `titan_uvshim_format_port`;
- `titan_uvshim_getaddrinfo_start`;
- `titan_uvshim_addrinfo_is_usable`;
- `titan_uvshim_addrinfo_count`;
- `titan_uvshim_addrinfo_copy`;
- `titan_uvshim_address_at`;
- `titan_uvshim_tcp_bind`;
- `titan_uvshim_tcp_connect_start`.

The exact cancel/free symbols
`titan_uvshim_getaddrinfo_cancel` and `titan_uvshim_addrinfo_free`, listed
generically in section 10.2, are deleted as part of the earlier cast-only
migration. The end state has no native DNS/address operation wrapper. It keeps
only:

- `titan_uvshim_getaddrinfo_cb` and `titan_uvshim_connect_cb` as externally
  visible plain-C callbacks;
- `titan_uvshim_address`, its alignment-probe structs, and the native
  compile-time assertions that the opaque cell is large and aligned enough for
  `struct sockaddr_storage`.

Implement DNS submission in `titan/uv/tcp.titan`:

1. Use the host and `0..65535` port already validated by the public
   `_net_connect`/`_net_listen` entry points, and cache the host, port, loop, and
   request inputs before publishing a request owner. Do not add duplicate
   checks merely because the deleted C wrapper asserted them.
2. Format that port into a zero-initialized
   `ffi.titan_ffi_char[6]`. Use a constant digit string through a C character
   pointer, C remainder/division, zero-based array writes, and array
   decay/pointer arithmetic; do not hardcode the execution character value of
   `'0'`.
3. Declare a zero-initialized `libuv.addrinfo` local and set exactly
   `ai_family = AF_UNSPEC`, `ai_socktype = SOCK_STREAM`,
   `ai_protocol = IPPROTO_TCP`, and `ai_flags = AI_NUMERICSERV`.
4. Prove `AF_UNSPEC`, `AF_INET`, `AF_INET6`, `SOCK_STREAM`, `IPPROTO_TCP`, and
   `AI_NUMERICSERV` import from the real bundled/system Linux and macOS header
   contexts. All currently supported configurations must expose
   `AI_NUMERICSERV`; if the custom preprocessor misses it, fix that import
   rather than silently changing the hints or retaining a wrapper.
5. After owner publication, perform only nonallocating field stores and direct
   C calls: install request data through `uv_req_set_data`, then call
   `uv_getaddrinfo` once with the native
   `titan_uvshim_getaddrinfo_cb`. Libuv copies the node, service, and hints
   during that call, so no automatic pointer escapes it.

Implement result normalization in Titan without exposing any platform address
fields:

1. Convert the callback's generic pointer once to `*libuv.addrinfo`, store that
   typed borrowed pointer in `NetRequestControl`, and capture it before entering
   an allocating body.
2. Traverse `ai_next` in resolver order. An entry is usable exactly when
   `ai_addr` is non-null, `ai_family` is `AF_INET` or `AF_INET6`, and
   `ai_addrlen <= libuv.sockaddr_storage.sizeof`. Do not compare against
   `titan_uvshim_address.sizeof`: that 256-byte cell is intentionally larger
   and would weaken the current predicate.
3. Count usable entries, allocate
   `shim.titan_uvshim_address.new_array(count)`, and store the owned userdata as
   `AddressList.storage`; derive `AddressList.data` from that `COwned` value
   rather than retaining a raw pointer alone. The existing typed allocator
   performs the exact element-size overflow check, supplies the union's
   alignment, and zeroes the complete cell array before any copy.
4. Traverse again and, only after the usability/size guard succeeds, explicitly
   convert `ai_addrlen` (`socklen_t`) to the `cstring.size_t` expected by
   `cstring.memcpy`. Store that converted local and copy exactly that many bytes
   from each usable `ai_addr` into the next cell's `bytes`, preserving resolver
   order. Titan never reads or writes a `sockaddr` field. Generated-C tests
   assert guard-before-conversion-before-call ordering; distinct C integer
   types do not gain a new implicit conversion.
5. Install the copied `AddressList` in `operation.addresses` before freeing the
   borrowed chain or calling any continuation/user code. Every non-null result
   is released exactly once through direct `uv_freeaddrinfo`, including
   allocation/copy longjmp, cancellation completion, ordinary failure, and
   runtime shutdown. `uv_cancel` remains logical cancellation; the callback
   still owns physical completion and retirement.

For bind/connect, compute the selected opaque cell pointer while the rooted
`AddressList` is live, convert it explicitly to `const *libuv.sockaddr`, and
call public libuv directly:

- `uv_tcp_bind(tcp, address, 0)` retains bind-before-listen ordering;
- connect precomputes the address and every potentially raising conversion
  before publishing the request owner, then installs request data and calls
  `uv_tcp_connect(req, tcp, address, titan_uvshim_connect_cb)`.

Preserve `connect_pending`, immediate-error retirement, failed-address
close-before-retry, resolver ordering, IPv4/IPv6 filtering, address-index
bounds already established by the candidate loop, exact error
operation/subject strings, and the existing rule that no allocating or
user-code call occurs between owner publication and asynchronous submission.
Do not translate the deleted helpers' non-null/index `assert(...)` calls into
new Titan validation.

## 11. Coroutine transfer rooting and the compiled-module ABI

### 11.1 Native code that remains

Keep:

- `titan_coro_tag_equal`, which uses Lua-internal equality;
- `titan_coro_entry`, which implements minicoro's native entry ABI;
- minicoro implementation/configuration and the module-lifetime
  `mco_runtime`;
- the invariant that coroutine owner userdata has exactly five uservalues at
  creation.

Do not move `mco_runtime` to automatic storage.

### 11.2 Titan-side root and clear

Replace current calls to `titan_coro_root_transfer` and
`titan_coro_clear_transfer` in `titan/coroutine.titan` with private Titan
helpers using public APIs:

1. Accept a nullable `mco_coro *` and return immediately for `NULL` where the
   current helper does.
2. Recover the owner with `mco_get_user_data`.
3. Keep it explicitly typed as `*ffi.Udata` so Titan's existing special bridge
   anchors the full userdata while Lua stack growth can collect.
4. Save `lua_gettop(L)`.
5. Reserve two stack slots with `lua_checkstack` and check its nonzero result
   before either push; on failure restore the saved top and raise the internal
   allocation/stack error.
6. Push the owner as its full-userdata `TValue` using the existing
   Udata-pointer bridge.
7. Push the transfer payload, or `nil` for clear.
8. Call `lua_setiuservalue` on
   `TITAN_CORO_OWNER_USERVALUES`.
9. Check the setter's nonzero result and restore the exact saved top before
   raising any internal error.

Lua's public setter performs the necessary object copy and GC back barrier.
Direct assignment to `Udata.uv` is forbidden: it would depend on Lua internals
and could omit the barrier.

Preserve the transfer choreography:

- install the root before the first `mco_push`;
- clear it on every push/resume rollback;
- after `mco_pop`, copy/refresh the returned `TValue` into the
  compiler-generated Lua-stack anchor before clearing the source owner;
- preserve `nil` as a valid payload;
- clear the exact source coroutine (`stacked_co`) rather than assuming the
  currently active coroutine owns the value.

Tests must force full and generational collections while a terminal result or
error is rooted, cover nested/resumed coroutines and nil, and assert generated
operation order:
anchored `*ffi.Udata`, checked `lua_checkstack`, owner/payload pushes, checked
`lua_setiuservalue`, and exact top restoration.

### 11.3 Compiled-module ABI 0.18

The C FFI source features do not themselves change serialized Titan types or
ordinary exported Titan native signatures. The complete standard-library
migration nevertheless changes the static runtime contract:

- the new `titan.a` logical objects directly reference callback trampolines
  that were `static` inside ABI-0.17 `titan_uv.o`;
- a final static executable supplies those definitions from `libtitan.a`;
- an older ABI-0.17 `libtitan.a` therefore cannot link a new provider;
- deleting old wrapper/root symbols also makes an older static provider
  incompatible with the new runtime.

A DSO can hide the first mismatch because its link pulls in the current
`titan_uv.o`, but ABI compatibility must also hold for archive-backed providers.
Do not ship a bidirectionally incompatible runtime/provider pair under the same
number. Bump the compiled-module ABI from 0.17 to 0.18.

The ABI history entry in `titan-runtime/titan.h` states that 0.18:

- promotes the callback trampolines needed by direct standard-library source
  into the runtime's external native symbol contract;
- removes the replaced libuv/coroutine helper-symbol contract;
- requires a 0.18 runtime and provider to be built/distributed together.

Perform the complete version migration:

- `driver.TITAN_VER = "0.18"` and suffix `_0_18`;
- `TITAN_VER`/suffix in `titan-runtime/titan.h`;
- `TITAN_ABI_VERSION` and every Makefile path/environment spelling;
- default compiled lookup and override `TITAN_PATH_0_18`;
- canonical SDK/stdlib pair at
  `$ROCKS_TREE/lib/titan/0.18/{titan.so,titan.a}`;
- the prefix Lua configuration input/stamp and rebuilt `luaconf.h` whose
  compiled Titan C-module path must name `lib/titan/0.18`, never stale 0.17;
- bootstrap staging, generated metadata, shims, validation images, snapshots,
  mode smokes, and all ABI fixtures/specs;
- documentation and `AGENTS.md` ABI history.

The 0.18 installer:

- treats a 0.18 bootstrap, legacy complete 0.18 DSO-without-archive, or complete
  0.18 pair as predecessor states for same-version publication/rollback;
- publishes and validates only the 0.18 pair;
- replaces the seven unversioned generated Lua shims only at final commit;
- leaves the complete `lib/titan/0.17` tree untouched;
- restores the exact prior 0.18 pair state and the exact preexisting
  unversioned shim set on injected failure. During same-prefix migration those
  seven shims may still be the ABI-0.17-generated set, so tests begin from that
  state and compare restored shim presence/content/mode/mtime rather than
  assuming every predecessor shim was generated by 0.18;
- does not claim crash/power-loss/signal atomicity.

Update the CI migration producer to prepare an ABI-0.17 prefix, run the
supported `make lua`/`make luarocks` plus first 0.18 rock installation in that
same prefix, prove that 0.17 artifacts remain separate, and prove bare
`require "titan"` after 0.18 publication with no stale 0.17 compiled cpath.
Tests also compile explicit 0.17 DSO/archive fixtures and require an ABI
mismatch before metadata use or native link rather than a late missing symbol.
Update current-version documentation broadly while retaining the historical
statement that dense Array boundary semantics began at ABI 0.17.

With the ABI bump in place, physically delete retired wrapper/root prototypes
and definitions after all current source callers are gone. No compatibility
block remains in `titan_uv.c` or `titan_coro.c`.

## 12. Implementation sequence

The phases are ordered so each layer is independently testable and the libuv
migration dogfoods only completed compiler behavior.

```text
preprocessor/constants ───────────────────────────────┐
exact C declarators ──> probe session ─> conversions ├─> libuv migration
                       toolchain profile ─> operators ┤
parser/types/declarations ─> aggregate spills ────────┘
named C tag publication ─> stack objects/DNS/address ─┘
public Lua uservalue path ─────────────────────────────> coroutine migration
all compiler/runtime changes ──────────────────────────> docs/package/CI
```

### Phase 0: Freeze representative current behavior

Before changing relations or lowering:

1. Add focused current-success cases for exact C pointers, qualifier addition,
   object/`void *`, struct local address-taking, imported arrays, C function
   pointers, named C calls, and variadic calls.
2. Add current-failure cases for libuv-style unrelated object pointers,
   qualifier removal, object/function pointer crossing, C aggregate operators,
   no-RHS locals, source `T[N]`, and a tag-only `struct S` referenced as `c.S`.
3. Record generated-C assertions for `&local`, array decay from an imported
   array, foreign call operand order, and current try spills.
4. Add a small libuv header fixture that uses typedef'd handles and callbacks
   without requiring the complete library suite.
5. Characterize the current parser facts separately from the source failure:
   `struct@S`/`union@U` are canonical internal entries, a real typedef is an
   ordinary type member, and a same-named function such as `stat()` remains an
   ordinary C-module value. Also pin the current omissions: an unsupported
   typedef can disappear before checker publication, and a forward tag reached
   only through a differently named typedef need not become a standalone raw
   entry.

These are characterization tests, not a commitment to preserve the failures.
They make the intentional diffs reviewable.

Exit criterion: the new characterization cases pass on unmodified behavior
where marked success and fail with the expected current diagnostic where marked
future.

### Phase 1: Correct preprocessing and preserve constant metadata

Files:

- `c-parser/cpp.lua`
- `c-parser/cdefines.lua`
- `spec/cpp_spec.lua`
- `spec/cdriver_spec.lua`
- `spec/ctypes_spec.lua`
- `spec/foreigntypes_spec.lua`
- focused checker/coder FFI specs

Work:

1. Refactor macro argument capture to preserve raw and prescanned forms.
2. Implement placemarkers, both-sided `##` substitution, paste validation, and
   post-paste rescan.
3. Keep recursion suppression and source diagnostics intact.
4. Preserve object-macro expression structure plus each integer token's base,
   suffix, and unsigned/rank candidates; do not finalize a target-dependent C
   type yet.
5. Prove the real pinned libuv header publishes the named `UV_E*` constants.
6. Prove a generated Titan module can compare a returned libuv C status to a
   direct enum constant.

Do not touch `titan_uv.c` yet. The old getter functions remain the production
path until the complete source migration.

Exit criterion: custom preprocessing agrees with the host preprocessor on the
focused macro corpus, direct `libuv.UV_EOF` typechecks and compiles, and all
preprocessor/parser tests pass.

### Phase 2: Expose named tags, extract exact declarators, and define target semantics

Files:

- `c-parser/ctypes.lua`
- new `titan-compiler/cdeclarator.lua`
- new `titan-compiler/csemantics.lua`
- `titan-compiler/checker.lua`
- `titan-compiler/coder.lua`
- `titan-compiler/foreigntypes.lua`
- `titan-compiler/symtab.lua`
- `titan-compiler/types.lua`
- `titan-dev-1.rockspec`
- `spec/ctypes_spec.lua`
- `spec/foreigntypes_spec.lua`
- `spec/symtab_spec.lua`
- new root `spec/cdeclarator_spec.lua` and `spec/csemantics_spec.lua`
- new `spec/checker/c_ffi_tag_names_spec.lua`
- new `spec/coder/c_ffi_tag_names_spec.lua`

Work:

1. Pre-scan each complete foreign-import `TypeList` for real typedef names,
   then publish eligible named `struct@S`/`union@U` entries under `c.S`/`c.U`
   as specified in section 4.1.
2. Extend `ctypes.register_types` with pre-conversion metadata for every
   syntactic file-scope typedef name and named file-scope tag declaration or
   reference. Preserve stable prototype scope/reference metadata without
   prematurely binding it; ensure differently named forward typedefs and
   file-scope pointer declarations retain a canonical raw tag entry, while
   prototype-scope-only tags never become alias candidates.
3. Add a module-wide file-scope tag registry in `symtab.lua`. During
   `foreigntypes` conversion, bind prototype references to an already-visible
   file-scope tag when present and otherwise intern them only within their
   prototype scope. Prove both import orders: prior file-scope reuse across
   headers and a later same-spelled file-scope tag remaining distinct.
4. Enforce C's shared per-scope struct/union/enum tag namespace. Same-header
   conflicts are fatal registrar/header errors rather than best-effort skips;
   cross-import conflicts are checker diagnostics carrying both headers and
   provenances.
5. Preserve raw canonical file-scope tag keys and completion identity; never
   manufacture a `CTypedef` or a bare global foreign-type entry for the
   synthetic name.
6. Make C-module expression lookup ordinary-value-first while type lookup uses
   the type namespace. Add a deliberate diagnostic for collided tag
   pseudo-members rather than hiding the ordinary value or guessing from a
   parent expression.
7. Centralize the frontier-aware complete-C-object check across by-value
   parameters/results, module/initialized/automatic locals, cast targets,
   fixed-array elements, allocation, pseudo-size operations, and field access;
   preserve pointer-only incomplete use.
8. Thread checker state into C pseudo-member validation so an incomplete or
   not-yet-visible tag rejects `.sizeof` and `.alignof`, while a complete FAM
   struct retains those two operations and its existing allocation rejection.
9. Prove real same-name typedef precedence in both declaration orders,
   including an unrelated or unsupported typedef target; prove forward
   completion/frontier behavior (including pseudo-size access before/after
   completion), differently named forward typedefs, file-scope pointer
   references, repeated same-prototype tag uses followed by a distinct
   same-spelled file-scope tag, prototype-scope exclusion, union parity,
   same-scope struct/union/enum kind conflicts, anonymous exclusion, and
   `struct stat` plus `stat()` coexistence.
10. Move all C spelling/declaration logic out of `coder.lua`.
11. Add exhaustive declarator tests for arrays, pointer-to-array,
   pointer-to-function, qualified pointers, typedef-preserving objects, and
   nested combinations, plus direct tag aliases that must render as
   `struct S`/`union U` with no invented typedef.
12. Replace every coder call site with the shared renderer without changing
   generated output for existing types.
13. Define the pure target-profile schema and implement/unit-test integer
    promotions and usual arithmetic conversions against injected LP64 and
    synthetic alternative profiles. Do not query a live compiler until Phase 3
    owns the shared effective toolchain descriptor.

Exit criterion: existing generated-C snapshots are unchanged except for
incidental whitespace; tag-only `c.S`/`c.U` works in type positions and emits
`struct S`/`union U`; same-named ordinary C values remain callable/readable;
direct C arrays render as arrays rather than pointers; promotion tests cover
LP64 plus a synthetic alternative profile without consulting the host
toolchain.

### Phase 3: Build the toolchain profile and add the session-scoped probe service

Files:

- new `titan-compiler/cprobe.lua`
- `titanc`
- `titan-compiler/driver.lua`
- `titan-compiler/checker.lua`
- `c-parser/cdriver.lua`
- `c-parser/cpp.lua`
- `c-parser/cdefines.lua`
- `titan-compiler/csemantics.lua`
- `titan-compiler/foreigntypes.lua`
- `titan-dev-1.rockspec`
- new `spec/cprobe_spec.lua`
- `spec/csemantics_spec.lua`
- `spec/foreigntypes_spec.lua`
- `spec/driver_spec.lua`

Work:

1. Introduce the lazy resolver-owned service plus per-module header context and
   thread them through `titanc`, `defaultloader`, `tableloader`, filesystem
   child compilation, and every checker invocation; direct checker calls create
   a fresh service unless one is injected.
2. Extract a shared driver toolchain descriptor/compile-argv builder and use it
   for generated objects, predefined-macro target profiling, and probes.
3. Derive target integer widths, ranks, ranges, and plain-char signedness from
   that descriptor's predefined-macro context, including target-selecting C
   flags and maximum-value macros.
4. Make `foreigntypes` instantiate canonical primitives from that profile,
   retaining explicit 128-bit entries only when the selected target publishes
   them, and finalize object-like integer macro expressions with profile-aware
   literal rules and usual arithmetic conversions.
5. Expose the CPP path's safely quoted POSIX captured-command helper through
   `cdriver` and reuse it for probes.
6. Build baseline and candidate sources through `cdeclarator`.
7. Reuse parsed `CC` and exact effective compile flags.
8. Add injected runner/temp-provider tests for:
   - command construction;
   - headers and source-relative quote imports;
   - baseline failure versus negative candidate;
   - success/failure caching;
   - cache-key changes after flags/header/toolchain changes;
   - cleanup on success, rejection, spawn error, and interruption;
   - quiet default and complete `-v` evidence.
9. Add one real-compiler success and one real-compiler rejection integration
   test using a tiny private header.
10. Reset the service when driver C configuration changes; prove two configured
   compiler identities never share cache results.
11. Prove `-v` is set before the first probe and service cleanup runs on every
   public success/error exit.

Exit criterion: no conversion/operator language behavior uses the probe service
yet, but all fake and real probe tests pass; the selected toolchain produces
the canonical target primitive profile; `UINT_MAX` has the correct target
type/value without host assumptions; and an installed `titanc` loads the new
modules.

### Phase 4: Implement contextual C pointer conversion

Files:

- `titan-compiler/checker.lua`
- `titan-compiler/types.lua`
- `titan-compiler/coder.lua`
- `titan-compiler/cprobe.lua`
- `spec/checker/c_ffi_spec.lua` or a new topical pointer-conversion spec
- `spec/coder/c_ffi_spec.lua` or a new topical pointer-conversion spec

Work:

1. Keep pure exact/known relations in `types.lua`.
2. Add checker-context adjustment and the unsafe object-pointer trait.
3. Add `volatile` to qualifier-preservation checks alongside `const`.
4. Thread the relation through every adjustment site listed in section 4.5.
5. Make the coder emit the exact target cast once; avoid nested redundant
   typedef-expanding casts.
6. Mark mutable local-address foreign calls for try-spill analysis without
   conflating an object-pointer reinterpretation with taking a new address.

Tests cover:

- `uv_tcp_t * -> uv_handle_t *`;
- `uv_pipe_t * -> uv_stream_t *`;
- `uv_fs_t * -> uv_req_t *`;
- direction reversal as a distinct cache entry;
- typedef-preserving source and target;
- `const`/`volatile` addition and forbidden removal;
- object/function rejection;
- array decay versus struct `&`;
- direct, named, function-pointer, assignment, local, and return contexts;
- one emitted cast and one probe for repeated identical conversions;
- baseline/header failure diagnostics.

Exit criterion: a focused Titan fixture calls public libuv close/cancel APIs
without cast wrappers and generated C builds cleanly with the active toolchain.

### Phase 5: Add automatic aggregates and fixed arrays

Files:

- `titan-compiler/parser.lua`
- `titan-compiler/ast.lua`
- `titan-compiler/pretty.lua`
- `titan-compiler/checker.lua`
- `titan-compiler/types.lua`
- `titan-compiler/coder.lua`
- `spec/parser_spec.lua`
- topical checker/coder C-stack-object specs

Work:

1. Parse a single typed local without `=` and a C-array type postfix.
2. Resolve/validate the declaration restrictions in section 5.1.
3. Represent zero initialization explicitly on the checked declaration (for
   example `_c_zero_init = true`), rather than fabricating a normal Titan
   expression result.
4. Give zero-init declarations a dedicated coder path before ordinary
   `_codeadjustedfixed`; emit exact declarators and `= {0}`.
5. Implement direct-array decay, fixed length, indexing, address conversion,
   and rejection of whole-array value operations.
6. Reject aggregate capture while allowing explicitly captured pointers.
7. Reject transitively GC-bearing automatic aggregates until/unless an exact
   anchor implementation is added.
8. Preserve existing by-value aggregate initialization and assignment.

Tests cover:

- parser/pretty round trip;
- zeroed struct, union, and each array element;
- zeroed complete tag-only struct/union locals through their section-4.1 base
  names, plus pointer-only success and automatic-object rejection for an
  incomplete tag;
- direct and typedef array declarations;
- exact `&object` versus `array` decay;
- pointer-local initialization and direct C argument use;
- zero-based reads/writes and `#array`;
- positive literal extent enforcement;
- incomplete, FAM, void, function, Titan, multiple-decl, and missing-extent
  rejection, plus rejection of standalone no-RHS scalar/pointer locals while
  arrays of complete scalar/pointer elements remain accepted;
- source `T[N]` rejection in parameters, results, aliases, records, casts,
  module variables, initialized locals, nullable types, and other general type
  positions;
- aggregate capture rejection/pointer capture acceptance;
- array assignment/return rejection;
- no regression to `COwned.new`/`new_array`.

Exit criterion: a standalone focused fixture constructs the complete
`uv_process_options_t`/three-element `uv_stdio_container_t` shape and a
zero-initialized tag-only `libuv.addrinfo` with source field access, although
production process spawn and DNS have not moved yet.

### Phase 6: Complete aggregate try spills

Files:

- `titan-compiler/coder.lua`
- `titan-compiler/checker.lua` for a definite `_c_mutated_decls` annotation on
  calls whose arguments take mutable aggregate addresses
- topical coder stack-object specs
- focused `try`/`catch`/`finally` execution cases

Work:

1. Teach lvalue write collection to find aggregate roots through fields and
   indexes.
2. Have the checker record each root aggregate in
   `call._c_mutated_decls`; treat the call as a possible whole-object write on
   normal return.
3. Add volatile byte spill declaration, update, and reload helpers.
4. Place updates after zero initialization, direct writes, and mutating calls.
5. Cover nested try regions, catch writes read by finally, finally writes read
   afterward, loop edges, and defer-tail predeclarations.
6. Inspect generated C with warnings enabled to ensure no volatile qualifier is
   cast away.
7. Distinguish a directly tracked `c.fill(array)` argument from storing the
   decay/address in a pointer and mutating through that alias later; document
   and test only the former as a committed write.

Exit criterion: executed fixtures survive a longjmp after struct field/array
element writes, and after a normally returned mutable foreign-call mutation,
and read the last committed representation.

### Phase 7: Implement C operator mode

Files:

- `titan-compiler/csemantics.lua`
- `titan-compiler/cprobe.lua`
- `titan-compiler/checker.lua`
- `titan-compiler/coder.lua`
- new `spec/checker/c_ffi_operators_spec.lua`
- new `spec/coder/c_ffi_operators_spec.lua`

Work:

1. Add checker dispatch before existing Titan operator paths.
2. Normalize arrays/pointers and mixed Titan operands.
3. Compute complete conversions/result traits.
4. Probe the exact lowered expression and cache the result.
5. Emit the C expression through ordered temporaries before any Titan helper.
6. Make every unsupported combination stop with a C-specific diagnostic rather
   than falling through to a generic Titan mismatch.

The matrix tests include every accepted row and exclusion, plus:

- small-integer promotions;
- signed/unsigned rank crossings;
- float rank;
- typedef identity dropping;
- bit-field rejection before an explicit ordinary-integer cast;
- C `-7 / 3 == -2` and `-7 % 3 == -1`;
- unsigned wrap;
- unnormalized shifts and xor spelling;
- `~=` to `!=`;
- mixed conversion before operation;
- `unsigned char + Titan integer`, proving promotion/UAC against configured
  `lua_Integer` without pre-narrowing, plus `length > UINT_MAX`;
- pointer arithmetic, array decay, compatible pointer difference,
  pointer/nil equality, and unrelated object-pointer equality through a
  symmetric qualified `void *` common type;
- incomplete/void/function-pointer restrictions;
- left-to-right effects with each operand evaluated once;
- result type assertions;
- probe cache hit and negative-cache behavior.

Exit criterion: focused compiled fixtures demonstrate C values/semantics while
equivalent all-Titan expressions retain Titan behavior.

### Phase 8: Migrate cast-only libuv paths

Files:

- owning `titan/uv/*.titan` contributors
- `titan-compiler/driver.lua`
- `titan-runtime/titan_uv.c`
- `titan-runtime/titan/uv.h`
- `titan-runtime/titan.h`
- `Makefile`
- `scripts/stdlib_installer.lua`
- `spec/abi_spec.lua`
- `spec/driver_spec.lua`
- `spec/support/ci_abi_migration_smoke.sh`
- `spec/support/ci_stdlib_snapshot.sh`
- `spec/support/ci_libuv_mode_smoke.sh`
- `.github/workflows/ci.yml`
- ABI-0.17 DSO/archive and stdlib migration fixtures/specs
- relevant stdlib specs
- delayed filesystem callback fixture/anchor generator

Work:

1. Own the complete ABI-0.18 foundation before emitting any new callback
   reference: runtime/compiler constants, `_0_18` symbols, default and override
   lookup, Lua configuration/cpath input, Make/staging paths, installer
   predecessor recognition, snapshots/smokes, and explicit ABI-0.17
   DSO/archive mismatch fixtures. Phase 12 later exercises final publication
   and rollback; it must not introduce the first usable 0.18 path.
2. Expose required callback trampoline symbols, including the DNS/connect
   callbacks needed by Phase 10, before any generated source refers to them.
3. Replace the section 10.2 wrapper calls with direct libuv calls.
   `uv_freeaddrinfo` receives a typed `*libuv.addrinfo` obtained through the
   new tag alias rather than another private typedef.
4. Preserve data installation and cleanup ordering one helper at a time.
5. Physically remove each obsolete cast-only prototype/definition after its
   last current source reference is gone.
6. Update the delayed-FS fixture's per-file anchors if source ownership moves;
   keep the timing hook private and contributor-specific.
7. Run each owning stdlib suite without LuaCov before beginning process spawn.

Exit criterion: new generated `titan.so`/`titan.a` contains no current references
to cast-only wrappers; the compiler/runtime/installer already agree on every
0.18 versioned path and reject 0.17 fixtures at the ABI check; and TCP, pipe,
timer, FS, signal, process cleanup, and late-callback behavior are unchanged.

### Phase 9: Migrate constants, process spawn, buffers, signals, and stat

Files:

- `titan/uv/uv.titan`
- `titan/uv/runtime.titan`
- `titan/uv/process.titan`
- `titan/uv/file.titan`
- `titan/uv/os.titan`
- `titan-runtime/titan_uv.c`
- `titan-runtime/titan/uv.h`
- stdlib/process/production smoke specs

Work:

1. Initialize error constants directly from `libuv.UV_E*`.
2. Replace signal mapping with Titan logic and imported platform constants.
3. Implement complete process options/stdio construction in Titan and call
   `uv_spawn` directly.
4. Preserve owner-data plus unconditional `PROCESS_SPAWNED` transition ordering
   on success and synchronous failure.
5. Add an explicit `string.h` foreign import in the canonical folder main; move
   buffer initialization through public `uv_buf_t` field lvalues and byte
   helpers through `cstring.memcpy`/`cstring.memcmp` under their existing owning
   Titan validation/control flow. Preserve valid
   empty/oversized-needle/terminator behavior and necessary post-validation
   narrowing, but do not translate defensive shim `assert(...)` predicates into
   new Titan branches.
6. Prove the exact bundled/system/macOS feature-test flags expose the required
   stat constants, then move stat extraction/classification.
7. Retain public maximum/offset validation tests and add focused zero-length,
   empty/oversized-needle, and NUL-termination cases plus generated-C assertions
   for the operational branches and post-validation casts.
8. Replace `UV_BUF_MAX` with a proven `UINT_MAX` path.
9. Remove `as integer` only where C-mode expressions make it redundant.
10. Delete all newly obsolete prototypes/definitions and assert neither the
   source tree nor generated 0.18 provider refers to them.

Exit criterion: process spawn/communicate, signals, filesystem stat, buffers,
TCP, and all error paths pass in both bundled and system libuv modes.

### Phase 10: Migrate DNS normalization, bind, and connect submission

Files:

- `titan/uv/tcp.titan`
- `titan/uv/task.titan`
- `titan/uv/uv.titan`
- `titan-runtime/titan_uv.c`
- `titan-runtime/titan/uv.h`
- `spec/checker/c_ffi_tag_names_spec.lua`
- `spec/coder/c_ffi_tag_names_spec.lua`
- `spec/stdlib/net_spec.lua`
- new `spec/stdlib/uv_late_dns_callbacks_spec.lua`
- new `spec/support/make_delayed_dns_callback_variant.lua`
- production/static/sanitizer net smokes

Work:

1. Under the exact bundled and system production flags, prove Linux and macOS
   expose complete `libuv.addrinfo`, `libuv.sockaddr`, and
   `libuv.sockaddr_storage` tag aliases plus every socket/addrinfo constant
   listed in section 10.4.
2. Verify and consume the Phase-8 declarations of
   `titan_uvshim_getaddrinfo_cb` and `titan_uvshim_connect_cb`, proving their
   callback types are exactly compatible across the separate `uv.h` and
   `titan/uv.h` foreign imports.
3. Move port formatting and zeroed `addrinfo` hints into `tcp.titan`, install
   request data, and call `uv_getaddrinfo` directly. Build every automatic
   argument before owner publication; do not reproduce defensive C
   `assert(...)` calls as Titan checks. Prove the private decimal formatter
   returns `"0"` for zero, crosses `9` to `"10"` in the correct order, and fits
   `"65535"` plus its terminating NUL in the six-byte automatic array.
4. Change the borrowed result field/helpers to `*libuv.addrinfo`, traverse and
   filter the chain in Titan, allocate a typed zeroed
   `shim.titan_uvshim_address.new_array(count)`, and copy each accepted address
   in resolver order through `cstring.memcpy`. After the size predicate, cast
   `ai_addrlen` explicitly from `socklen_t` to `cstring.size_t`, and assert the
   generated guard/cast/call order.
5. Preserve the exact `sockaddr_storage.sizeof` length predicate, GC rooting
   before release, and exactly-once `uv_freeaddrinfo` ownership across success,
   error, cancellation completion, longjmp, and runtime shutdown.
6. Replace address lookup, bind, and connect-start wrappers with a rooted cell
   pointer, an explicit `const *libuv.sockaddr` conversion, and direct
   `uv_tcp_bind`/`uv_tcp_connect` calls. Precompute every potentially raising
   address/conversion before linking a connect owner.
7. Preserve failed-address close-before-retry, IPv4/IPv6 candidate order,
   `connect_pending`, bind-before-listen, synchronous failure retirement, and
   all operation/subject error labels.
8. Physically delete every helper/prototype listed in section 10.4 and prove
   generated logical archive members have the required undefined references to
   the two callbacks and no reference to a removed DNS/address symbol.
9. Add a narrow isolated DNS variant, analogous to the existing delayed-FS
   flow. It copies the complete `titan/uv/` contributor ensemble and patches
   unique anchors in the owning DNS code. It captures the successful non-null
   pointer in `NetRequestControl.result_pointer` and defers immediately there,
   before `dns_dispatch_body` and before the lifecycle changes from
   `NET_OWNER_SUBMITTED` to `NET_OWNER_CALLBACK`; shutdown therefore cannot
   prematurely retire it through the callback-state sweep. The variant also
   injects a raise after pointer capture/during copy, counts the non-raising
   direct `uv_freeaddrinfo` call, and exposes the private port formatter's
   result for boundary tests. A separate variant flag prepends one zeroed
   invalid opaque cell before the copied valid cells, without inspecting any
   `sockaddr` field; the first `uv_tcp_connect` must fail synchronously, its
   initialized handle must close, and only then may the valid-cell retry
   proceed. Its delayed-delivery owner is explicitly cleanup-shielded: the
   variant patches a unique
   `task.titan`/`close_all_owners` anchor so Runtime shutdown preserves that one
   owner until it delivers the held result, retires the DNS control, and then
   closes it. Keep every hook out of installed modules and assert the release
   counter is immediately adjacent to the direct C call, with no allocating
   operation between them.
10. Use that variant for deterministic cancellation, late-success,
    copy-longjmp, shutdown, formatter boundaries, and follow-up cases proving
    exactly-once release, no stale resume, and Runtime reuse. Force full and
    generational GC after `operation.addresses` receives the owned array and
    across a failed first candidate's close-before-retry window, then complete
    the next bind/connect through the surviving rooted raw cell pointer. Retain
    the existing localhost IPv6-to-IPv4 retry, explicit IPv4, optional IPv6,
    and listener round trips.

Exit criterion: DNS submission, result normalization, bind, and connect
submission are implemented in Titan; the opaque address cell, its native
compile-time layout assertions, and the two callback trampolines remain C; all
net suites and bundled/system/static/sanitizer smokes pass; and neither the
active header, runtime, nor 0.18 provider references a removed DNS/address
helper.

### Phase 11: Migrate coroutine transfer rooting

Files:

- `titan/coroutine.titan`
- `titan-runtime/titan_coro.c`
- `titan-runtime/titan/coro.h`
- `spec/stdlib/coroutine_spec.lua`

Work:

1. Implement private Titan root/clear helpers through public Lua APIs.
2. Replace every transfer site while preserving exact ordering.
3. Delete the old root/clear prototypes and definitions under ABI 0.18.
4. Extend generated-C ordering assertions.
5. Inject `lua_checkstack` failure and prove no push occurs and the exact top is
   restored.
6. Run terminal result/error, rollback, nil, nested, full-GC, and generational
   GC cases.
7. Prove `titan_coro.o` remains an exact member of `libtitan.a`.

Exit criterion: current generated coroutine code has no references to the old
root/clear helpers and all GC stress cases pass.

### Phase 12: Package, document, and close

Files include:

- `Makefile`
- `titan-dev-1.rockspec`
- `scripts/stdlib_installer.lua`
- `spec/support/ci_abi_migration_smoke.sh`
- packaging/installer specs
- both manual indexes/chapters listed in section 14
- `AGENTS.md`

Work:

1. Exercise the already-landed Phase-8 0.17-to-0.18
   driver/runtime/Makefile/installer/spec/CI migration through clean
   installation, same-prefix upgrade, publication, and rollback, and verify the
   old versioned tree is preserved.
2. Verify new compiler modules install and source/stamp dependencies invalidate
   the pair.
3. Rebuild all seven standard roots in one compiler process.
4. Validate the canonical DSO/archive pair, seven shims, eight `luaopen_*`
   entries, exact seven archive metadata keys, bundled payload, and system-mode
   external link requirements.
5. Preserve exact `libtitan.a` members:
   `titan.o`, `titan_coro.o`, and `titan_uv.o`.
6. Test explicit 0.17 DSO/archive rejection by the 0.18 loader and the
   same-prefix upgrade/publication/rollback path.
7. Update both manuals and repository guidance in the same commit series as the
   implementation.
8. Run the complete validation ladder in section 15.

Exit criterion: installed and checkout compilers behave identically, package
publication/rollback tests pass, documentation describes the shipped boundary,
and exact-head Linux/macOS evidence is green.

## 13. Test ownership and named fixtures

### 13.1 Pure/parser/tool tests

- `spec/cpp_spec.lua`: raw/prescanned/stringize/paste/rescan rules.
- `spec/cdriver_spec.lua`: real libuv header and include descriptors.
- `spec/ctypes_spec.lua`: enum publication, array/typedef declaration facts,
  distinct raw `struct@T`/`union@T` tag entries, complete syntactic typedef-name
  reservation before conversion, differently named forward-typedef tag
  retention, stable unresolved prototype-reference metadata, and fatal
  same-header shared-tag-kind conflicts.
- `spec/foreigntypes_spec.lua`: target primitive profile, constant types,
  prior-file-scope tag binding, prototype-local interning, and later
  same-spelled file-scope separation.
- `spec/symtab_spec.lua`: module-wide file-scope tag reuse/completion and
  provenance-bearing cross-import kind conflicts.
- `spec/cprobe_spec.lua`: runner/session/cache/temp/diagnostic behavior.
- `spec/cdeclarator_spec.lua`: exact C grammar rendering.
- `spec/csemantics_spec.lua`: categories, promotions, common types, and target
  profiles.
- `spec/parser_spec.lua`: no-RHS local and C fixed-array syntax.
- `spec/types_spec.lua`: only pure unchanged relations; no compiler probes.

### 13.2 Checker tests

Use topical files for the sizable new behavior:

- `spec/checker/c_ffi_tag_names_spec.lua`;
- `spec/checker/c_ffi_pointer_conversions_spec.lua`;
- `spec/checker/c_ffi_stack_objects_spec.lua`;
- `spec/checker/c_ffi_operators_spec.lua`.

Keep small regressions in existing `c_ffi_spec.lua` only where they extend an
existing focused context. Fake probe sessions make checker rejection tests
deterministic; at least one layer integration uses the real configured
compiler.

Tag-name coverage includes:

- complete struct and union aliases plus incomplete pointer-only use;
- forward completion within and across imports, including module-variable
  visibility frontiers and `.sizeof`/`.alignof` rejection before the definition
  becomes visible;
- incomplete-by-value rejection at function parameter/result, module variable,
  initialized/automatic local, cast target, and fixed-array element sinks;
- real same-name typedef precedence in both declaration orders, including an
  unsupported typedef target that must still reserve the name;
- anonymous aggregate exclusion, differently named forward-typedef
  coexistence and file-scope pointer-reference inclusion;
- prototype references binding to an already-visible file-scope tag within one
  header closure and across ordered imports, versus repeated prototype-local
  uses followed by a distinct later same-spelled file-scope tag;
- fatal shared tag-namespace rejection for same-header and cross-import
  struct/union/enum kind conflicts with both provenances;
- `struct stat` plus same-named function, static function, object, enumerator,
  and imported object-macro values, proving type lookup and expression lookup
  select their separate namespaces;
- a clear rejection for collided `.new`/`.new_array`/`.sizeof`/`.alignof`
  pseudo-members rather than hiding the ordinary value, plus a same-named
  imported aggregate object whose real fields are named `new` and `sizeof` to
  prove ordinary field lookup is never stolen.

### 13.3 Coder tests

Mirror the topical checker split under `spec/coder/`. Assert both generated C
and executed behavior:

- tag-only aliases emit exact `struct T`/`union T` declarations and no
  synthesized typedef;
- exact declarators and zero initialization;
- exact cast placement;
- operand/call order;
- C result semantics;
- volatile spill loops;
- direct libuv header integration.

Every generated fixture removes only its exact `.c`, `.o`, `.so`, `.a`, shim,
and executable outputs. It must never remove Make-owned
`titan-runtime/libtitan.a` or the shared standard provider.

### 13.4 Standard-library tests

Library behavior remains outside LuaCov:

- `spec/stdlib/coroutine_spec.lua`;
- all uv/timer/fs/net/os/process suites;
- `spec/stdlib/uv_late_fs_callbacks_spec.lua`;
- `spec/stdlib/uv_late_dns_callbacks_spec.lua`;
- `spec/stdlib/loadlibglobal_spec.lua` where provider loading matters.

The delayed-FS variant continues to copy the complete `titan/uv/` contributor
ensemble and patch unique owning-file anchors. The new DNS variant follows the
same isolated exact-provider pattern and adds only delayed logical DNS
delivery, copy-failure injection, formatter observation, GC checkpoints, an
optional leading zeroed invalid address cell, and a release counter adjacent to
the direct `uv_freeaddrinfo` call. Its variant-only delayed-delivery owner is
cleanup-shielded through shutdown so the held borrowed result cannot be
stranded by the ordinary timer-owner close sweep; deferral occurs before the
DNS control leaves `NET_OWNER_SUBMITTED`, so the callback-state retirement
sweep cannot free it first. Moving a helper requires moving its test anchor,
not adding a checkout-global timing or fault mode.

`spec/stdlib/net_spec.lua` remains the principal DNS/address integration proof:
retain resolver-order localhost fallback, IPv4, optional IPv6, bind/listen, and
connect round trips plus ordinary DNS failure/follow-up behavior.
`spec/stdlib/uv_late_dns_callbacks_spec.lua` owns deterministic late-success,
cancellation, injected copy-longjmp, shutdown, exactly-once result release, no
stale resume, formatter values `0`/`9`/`10`/`65535`, full/generational GC after
the owned address root is installed and across failed-candidate retry, and
Runtime-reuse proof.

### 13.5 Packaging and production tests

- `spec/libuv_build_spec.lua`: exact runtime archive membership.
- `spec/rockspec_spec.lua`: installed module inventory, SDK pair, external DSO
  promotion, and bundled/system focused assertions.
- `spec/stdlib_installer_spec.lua`: pair publication and rollback unchanged.
- `spec/support/ci_libuv_mode_smoke.sh`: both modes.
- `spec/fixtures/libuv/os_production_smoke.lua`: process spawn/communicate.

Extend the static provider smoke with one process child round trip, one
`fs.stat` assertion, and one local resolve/bind/connect round trip so process
construction, stat classification, and the migrated DNS/address path are
proved through archive-backed validation, not only checkout tests.

Inspect generated logical objects or individual `titan.a` members directly:
they must have the expected undefined references to the newly external callback
trampolines, including DNS/connect, and no references to removed helpers. Do
not infer this from `titan.so`, whose link against `titan_uv.o` can mask the
static boundary.

## 14. Documentation

Update both manuals as part of the feature.

### 14.1 Language manual

Add `doc/language/c-ffi-expressions.md`, linked from
`doc/language/index.md` and from the overview in `doc/language/ffi.md`, with:

- source-visible base names for named file-scope tag-only structs/unions, real
  typedef precedence, non-file-scope exclusion, incomplete-type limits, and
  exact `struct T`/`union T` C spelling;
- C tag versus ordinary-value namespace behavior, including `struct stat` plus
  `stat()` and the collided pseudo-member limitation;
- unsafe host-validated object-pointer conversions and qualifier guardrails;
- the fact that libuv handle conversion is a cast convention, not inheritance;
- no-RHS zero-initialized C local syntax;
- fixed C array syntax, length, zero-based indexing, decay, and assignment
  restrictions;
- automatic-storage lifetime and no escape analysis;
- the complete C operator table and mixed Titan/C rules;
- C promotions/result types and direct operator spelling;
- C undefined/implementation-defined behavior;
- direct enum/object-like macro constants;
- a process-options example using a neutral host-provided C callback fixture,
  not Titan's private libuv dispatcher callbacks.

Cross-link existing expression/operator and local-declaration chapters where
the new syntax changes their grammar. Keep `doc/language/ffi.md` as the
foreign-import/type/ownership overview and put the new declaration, conversion,
operator, and lifetime contract in the dedicated chapter.

### 14.2 Implementation manual

Add `doc/implementation/c-ffi-expressions.md`, linked from
`doc/implementation/index.md` and from `doc/implementation/ffi-internals.md`,
with:

- internal `struct@T`/`union@T` canonical identity, complete-TypeList typedef
  and file-scope tag metadata, the shared per-scope C tag namespace,
  ordered outer-tag binding versus scoped prototype-local tags, fatal
  cross-import kind conflicts, synthetic CModule type publication,
  dual-namespace lookup, complete-object sinks, forward completion/frontiers,
  and no fake `CTypedef`;
- `cdeclarator`, `csemantics`, and `cprobe` ownership;
- session lifetime/cache keys/baseline distinction;
- exact toolchain and include fidelity;
- contextual conversion traits versus pure `types.compatible`;
- target arithmetic profile and promotion algorithm;
- aggregate zero-init and volatile byte spills;
- checker/coder trait handoff;
- preprocessor `#`/`##` correction.

Keep `ffi-internals.md` as the pipeline/type/ownership overview and update its
source map to point to the new declarator, semantics, and probe modules.

Update:

- `doc/implementation/checker.md` where it describes foreign-import
  `type_members`, adding pre-conversion tag/typedef metadata, typedef
  precedence, the module-wide file-tag registry and ordered prototype binding,
  value-first C-module expression lookup, complete-object/frontier checks, and
  collided pseudo-member diagnostics;
- `doc/implementation/libuv-runtime.md` with the new native/Titan ownership
  table, ABI-0.18 callback/runtime boundary, direct constants, Titan-owned DNS
  submission/normalization/bind/connect logic, and the retained opaque address
  cell plus native callbacks/compile-time layout assertions;
- `doc/implementation/libuv-networking.md` with Titan-owned DNS submission,
  typed borrowed-result traversal and direct release, bind/connect submission,
  the narrower portable shim boundary, and the new deterministic DNS-variant
  verification ownership;
- `doc/implementation/coroutines.md` with public-API uservalue rooting and exact
  transfer ordering;
- `doc/async-with-coroutines.md` where it describes transfer rooting;
- implementation index summaries/links as needed.

Update `AGENTS.md` after the implementation so future work knows:

- probes share exact `CC`/flags and are compile-only/session-scoped;
- `UV_E*` values import directly;
- named tag-only structs/unions use base-name Titan type aliases without fake C
  typedefs;
- which native callback/layout/signal boundaries remain after every operational
  libuv wrapper, including DNS/address wrappers, is removed;
- the isolated exact-provider delayed-DNS variant owns its unique contributor
  and `close_all_owners` anchors, cleanup-shielded delivery, release/fault/GC
  hooks, and no-installed-hooks invariant alongside the existing delayed-FS
  exception;
- automatic aggregates and C operators are supported;
- ABI 0.18 is required because archive-backed providers directly reference
  newly external callback trampolines and no longer reference old helpers.

## 15. Validation ladder

Use isolated absolute prefixes for any clean installation proof. Do not rely on
checkout-local Lua modules being selected ahead of the installed rock.

1. Run focused pure/parser/declarator/preprocessor/probe specs, including raw
   tag registration and real-header tag exposure.
2. Run focused checker/coder FFI specs from the repository root, including
   tag/typedef/value namespace collisions and exact `struct`/`union` spelling.
3. Run focused coroutine and each affected uv/timer/fs/net/os/process suite
   without LuaCov.
4. Run packaging, libuv build, and stdlib installer specs serially against a
   prepared provider.
5. Run:

   ```sh
   make test
   ```

6. Run the same grouped split used by CI:

   ```sh
   "$PREFIX/bin/luarocks" make
   bash spec/support/ci_test_groups.sh libraries
   bash spec/support/ci_test_groups.sh compiler
   ```

7. Run bundled and system production smoke coverage, including the new static
   process/stat and resolve/bind/connect cases.
8. Run the focused ASan/UBSan native-memory gate and production net/OS smokes;
   add focused coroutine terminal result/error transfer cases under forced full
   and generational GC so the new Udata/Lua-stack root path is exercised, not
   only minicoro entry.
9. Perform adversarial source/diff review for:
   - accidental widening of `types.compatible`;
   - probes using a different compiler/header/flag context;
   - fake typedefs, declaration-order-dependent tag aliases, or C tag/value
     namespace collisions;
   - qualifier or object/function-pointer holes;
   - array declarator/decay errors;
   - untracked aggregate writes across longjmp;
   - C operands falling into Titan codegen;
   - callback/data/GC ordering regressions;
   - any remaining reference to removed helpers;
   - ABI, docs, and packaging claims.
10. Push only after local review and obtain green regular Linux CI.
11. Once the exact head is otherwise final, run one complete manual macOS
    pre-merge dispatch:

    ```sh
    gh workflow run ci.yml --ref <branch>
    ```

    Confirm the completed run is for the exact branch head. macOS is required:
    signal values, tag-only system types, DNS constants, headers, integer data
    model, system libuv, generated probes, and universal archive validation are
    target-specific.

Report Codecov upload success separately from any coverage-policy result.

## 16. Acceptance criteria

The feature is done only when all of the following are true:

- `libuv.UV_EOF`, `UV_EIO`, `UV_ECANCELED`, and related enumerators import
  directly from the real header.
- `UINT_MAX` imports with correct unsigned rank/value on Linux and macOS.
- A repeated exact probe compiles once per session; changed toolchain/header/
  flags produce a distinct result.
- Probe baseline failures and candidate rejections have distinct diagnostics.
- Every named file-scope tag-only complete struct/union without a real
  same-name typedef is usable as `c.NAME` in type syntax and generates exact
  `struct NAME`/`union NAME` C; incomplete tags are pointer-nameable and
  complete in place under the existing visibility-frontier rules, while
  every by-value/layout-requiring sink and `.sizeof`/`.alignof` reject an
  incomplete or not-yet-visible definition.
- A real same-name typedef always wins independent of declaration order,
  including when its target is unsupported; differently named forward typedefs
  retain the raw tag, anonymous/non-file-scope tags receive no invented module
  name, a prototype reference binds to an already-visible file-scope tag,
  otherwise repeated prototype-scope uses share only their local identity, and
  a later same-spelled file-scope tag remains distinct. Conflicting
  same-header/cross-import struct/union/enum kinds are fatal through C's shared
  tag namespace. No fake `CTypedef`, alias header, bare global foreign-type
  entry, serialized type, or ABI change is introduced by tag publication.
- Same-named C functions, static functions, objects, enumerators, and object
  macros remain usable as ordinary values; type and expression lookup preserve
  C's separate tag and ordinary namespaces, with an explicit diagnostic for
  collided type pseudo-members and no interference with real aggregate fields
  named `new`/`sizeof`.
- `uv_tcp_t *` can flow to `uv_handle_t *` through one explicit generated C
  cast; qualifier loss and object/function crossing remain errors.
- Every call/assignment/return/function-pointer/named-call adjustment path uses
  the same directional conversion policy.
- Zero-initialized complete C struct, union, and fixed array locals work; all
  forbidden no-RHS forms fail at compile time.
- Struct address-taking and array decay generate distinct correct C.
- Automatic aggregate reads after Titan longjmp observe the last direct Titan
  write or normal-return mutable-call commit; partial mutation by C followed by
  C-side nonlocal exit and later/asynchronous pointer-alias mutation remain
  explicitly unsafe.
- Every supported C operator has its specified result type and C behavior;
  every excluded operator fails without entering Titan helpers.
- Non-C Titan arithmetic/comparison/bitwise behavior is unchanged.
- Process spawn is implemented in Titan with the exact current initialization,
  rooting, callback, owner-data, unconditional post-attempt
  `PROCESS_SPAWNED` transition, and cleanup behavior.
- Buffer field initialization/copy/find/text behavior preserves the existing
  public validation plus valid zero-length, empty/oversized-needle, and
  terminator behavior, without recreating deleted defensive C assertions as
  Titan branches.
- Direct libuv error, signal, buffer, stat, TCP, pipe, timer, FS, process, DNS,
  bind, and connect paths pass their complete library suites.
- DNS submission, borrowed-`addrinfo` traversal, normalized-address copying,
  bind, and connect submission are implemented in Titan. Resolver order,
  IPv4/IPv6 filtering, callback-owned cancellation completion, and exactly-once
  result release are unchanged; each `socklen_t` copy length is converted
  explicitly to `cstring.size_t` only after the
  `sockaddr_storage.sizeof` predicate.
- Titan port formatting produces exact NUL-terminated decimal services for
  `0`, `9`, `10`, and `65535`; the owned normalized-address array and its raw
  cell pointer survive forced full/generational GC through release and
  failed-candidate close-before-retry.
- The normalized opaque address cell and its native compile-time size/alignment
  assertions remain C-owned, but Titan neither interprets platform `sockaddr`
  fields nor reproduces deleted wrappers' defensive runtime assertions.
- Coroutine result/error/nil transfers survive forced full and generational GC
  through Titan-side uservalue rooting.
- Native callback trampolines, compile-time layout assertions, `SIGPIPE`,
  coroutine entry, and tag comparison remain C.
- Retired wrapper/root symbols are absent from the active headers/runtime, and
  the 0.18 provider references only the new callback/runtime boundary.
- Direct inspection of 0.18 logical archive objects shows required undefined
  callback references and no removed-helper references; DSO linkage is not used
  as a proxy for this proof.
- Explicit 0.17 DSO/archive fixtures fail at the 0.18 ABI check rather than at a
  later native link, while the separate installed 0.17 tree remains untouched.
- `libtitan.a` retains exactly its three intended members.
- The canonical standard DSO/archive pair advertises exactly seven logical
  modules and validates in bundled and system modes.
- Both manuals, implementation ownership docs, and `AGENTS.md` match the
  shipped behavior.
- `make test`, grouped Linux jobs, sanitizer gates, bundled/system production
  smokes, regular exact-head Linux CI, and one exact-head macOS dispatch pass.

## 17. Risks and review traps

### Treating a warning as a proof

An uncast incompatible-pointer assignment may exit successfully when warnings
are not errors. Validate the explicit construct Titan actually emits and keep
category/qualifier rules in the checker.

### Letting probes become semantic state

Probe answers depend on headers/toolchain, but pure type equality and serialized
module interfaces must not. Keep results on checked expression traits and out of
public `Type.Module` serialization.

### Computing C result types from the Titan host

The Lua process's integer widths and signed `char` do not describe a
cross-compiler target. Use configured compiler predefined macros and reject
unknown extensions.

### Validating different C than the coder emits

Ad-hoc probe declarations can accept while final nested arrays/function pointers
fail. One declarator renderer and exact expression traits are mandatory.

### Losing GC safety while removing a tiny helper

Process argv, owner data, late callbacks, and coroutine payload roots are more
important than reducing C line count. Preserve anchoring/order explicitly and
keep callback trampolines native.

### Introducing longjmp undefined behavior

Automatic C aggregates make existing scalar spills insufficient. Complete the
byte-spill path or reject affected programs; do not defer the issue invisibly.

### Overclaiming shim completion

Tag-only base-name publication removes the old DNS type-spelling blocker.
Leaving operational DNS/address helpers behind because `struct@T` was not
wired into the Titan type namespace is incomplete. Conversely, moving the
operations does not authorize replacing or interpreting the opaque address
cell: keep its native layout proof, copy only the accepted byte count, and use
`sockaddr_storage.sizeof` rather than the deliberately larger cell size.

### Flattening C's separate namespaces

Do not manufacture a `CTypedef`, add the synthetic base name to global C
declaration lookup, infer exportable scope merely by stripping a surviving raw
key, publish aliases while streaming before a later typedef is known, or let a
tag type hide a same-named C function/object. Real typedefs win the type name;
ordinary members win expression lookup; explicit registrar metadata selects
file-scope tags; raw `struct@`/`union@` keys retain canonical file-scope
identity and completion; and an unresolved prototype reference consults the
ordered module-wide registry before creating a scoped local tag. Do not treat
raw struct/union/enum prefixes as separate C tag namespaces, silently skip kind
conflicts, or intern a genuinely local prototype tag globally: the base name is
shared within a scope.

### Missing an ABI-versioned path

Private-looking runtime symbols are native dependencies of archive-backed
providers, which is why this plan chooses ABI 0.18. Audit every `0.17`,
`_0_17`, and `TITAN_PATH_0_17` source/test/doc occurrence: the new toolchain
must consistently use 0.18, migration tests must intentionally retain 0.17
fixtures, and the installer must never overwrite/purge the separate 0.17 tree.

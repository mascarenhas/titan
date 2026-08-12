# FFI wrapup

Status: complete design for the ABI-0.23 implementation on
`feature/ffi-wrapup`. This closes the roadmap item formerly called “FFI with C,
continued”. Adopted pointers are not part of the design or the roadmap.

## Supported trust model

The C FFI is a boundary for a trusted C programmer. Titan preserves the checked
C declaration and target profile and preserves Titan source evaluation order,
but it does not turn raw C into a memory-safe language. In particular, a
Titan-written C-ABI function uses raw C pointer, indexing, arithmetic, cast, and
callback behavior. It has no hidden Lua state from which the compiler could
manufacture Titan null, bounds, range, ownership, or error checks. Undefined C
behavior remains undefined C behavior.

This is intentional, not an adversarial-input gap. The design does not add
registry indirection, callback registries, compatibility objects, pointer
provenance recovery, or defensive validation beyond the actual typed/source
boundary.

## Titan-written C-ABI functions

### Declaration and type syntax

A source module may define a top-level foreign function:

```titan
foreign function compare(left: *c.Item,
                         right: *c.Item): c.int
  if left.key < right.key then return -1 as c.int end
  if left.key > right.key then return 1 as c.int end
  return 0 as c.int
end
```

There is no `local` modifier, method form, record-static form, or nested form.
Every foreign function is source-only even though its non-inline C definition
has hidden external linkage so another co-generated source translation unit can
call it.

The corresponding source-written function-pointer type is:

```titan
local type Compare = foreign (*c.Item, *c.Item) -> c.int
local type Notify = foreign (*c.Item) -> ()
```

`foreign (P...) -> R` denotes a pointer to the raw C function type, while a
`foreign function` declaration is the C function designator itself. It does not
add another semantic callable type: the checker lowers the type constructor to
`CPointer(CFunction(...))` and the declaration to `CFunction(...)`. A foreign
declaration is callable directly and can decay only to an exactly compatible C
function pointer. It is never a Titan `Type.Function`, closure, module value,
or Lua-callable member.

Parameters and the optional single result must be direct declarable C FFI
types. `()` means C `void`. Written `void` parameters/results, `owned` views,
direct function/array values, Titan types (including `value`), input variadics,
multiple results, and flexible results are rejected. Use a pointer for an array
or callback parameter. Complete by-value C aggregates are allowed; incomplete
aggregates are allowed only behind pointers.

Direct C calls retain C arity. Named-call syntax is available only when the
direct declaration supplies one complete fixed parameter-name list.

### Source-only visibility

The current module can use its own foreign declarations. A direct source import
can use the producer's foreign functions through the written module alias. This
is the same direct-only compiler capability as other source-private members:

* the producer records the function only in its source collaboration view;
* a consumer must have its own direct source edge to the producer;
* another module cannot relay the capability transitively;
* a `.so`/`.a` interface, Lua, static co-residence, registry state, and symbol
  discovery expose no foreign member; and
* the producer's `foreign import` aliases are never imported as Titan names.

A generated C-header include is declaration plumbing, not authorization.

### Restricted raw-C body

A foreign body has its own raw-C checking and lowering context. It can see only
its parameters and locals, current-module foreign functions, direct-source
foreign members, imported C namespaces, and the C types/pseudo-values needed by
those declarations. Ordinary Titan module variables/functions/nominals and the
implicit ordinary-function locals `L` and `M` are absent.

The admitted statements are blocks/`do`, initialized local declarations,
assignment, C call statements, `if`/`elseif`/`else`, `while`, `repeat`, numeric
`for`, `break`, and `return`. The body rejects generic `for`, `case`,
`raise`, `catch`, `finally`, `defer`, lambdas, bound methods, Titan
constructors, variadic expressions, `is`, concatenation, Titan `and`/`or`/`not`,
and Lua-owned `.new`/`.new_array` allocation.

All locals have direct C types and an initializer. Conditions use C scalar
truth. A numeric `for` uses C integer/floating comparison and addition; its
start, limit, and step are evaluated once in source order. Literal zero steps
are rejected, and a dynamically computed zero step violates the trusted
programmer precondition. C overflow and other C operator behavior are not
replaced with Titan numeric semantics.

Literals are contextual raw C values: booleans are `_Bool`, integers default to
the target `int`, floats to `double`, strings to `const char *` with static
storage, and `nil` to contextual `NULL`. Calls, operands, and assignment values
are materialized so Titan's left-to-right, evaluate-once source rule survives
C's otherwise unspecified operand/argument evaluation order.

Raw pointer field/index/call lowering adds no Titan NULL or bounds check. A
foreign body may explicitly call the Lua C API when it has an explicit
`lua_State *`; any longjmp from that call crosses the boundary according to the
C API contract. Titan installs no `setjmp`, roots, cleanup, or recovery frame.

### C names and entry families

ABI 0.23 gives every top-level function family one readable module/member
boundary. The separator is the C99 universal-character-name spelling
`_\u2133_` (SCRIPT CAPITAL M), which cannot occur in a Titan identifier:

```text
module foo.bar, function baz -> foo_bar_\u2133_baz_titan
```

Ordinary public and local top-level functions use that prefix for the native,
Lua-stack, and strict entries, for example:

```text
foo_bar_\u2133_baz_titan
foo_bar_\u2133_baz_titanentry_lua
foo_bar_\u2133_baz_titanentry_strict
```

A foreign function uses the same native-family spelling and has no Lua or
strict entry. Public/local/foreign is a visibility and representation property,
not a second mangling scheme. There is no universal `titan_` symbol prefix and
no source-private hexadecimal encoding. Existing independent preflight checks
still reject flattened module-name collisions and collisions in other symbol
families.

### Generated `*.titan.h` artifact

A logical source module with at least one foreign function owns one reserved,
source-adjacent generated header:

```text
flat foo/bar.titan        -> foo/bar.titan.h
folder foo/bar/bar.titan  -> foo/bar/bar.titan.h
```

Only the flat source or canonical folder main owns it; contributors never own
headers. The same rule applies under an external `--tree`. The `*.titan.h`
spelling is compiler-owned and is deliberately distinct from an author-owned
same-stem `.h`.

Before compiling any source object, the driver prepares every header in the
source graph. A header has a generated-file banner and guard, ordered direct C
imports, supplemental origin headers required by rendered C types, generated
headers of direct source dependencies that define foreign functions, all
function declarations, and then eligible inline bodies. Generated C includes
its own companion header, so C checks prototype/definition agreement.

A foreign function is emitted `static inline` in the header only when, after an
optional prefix of direct local declarations, its root body is exactly one of:

1. `return expression`;
2. one `if` with a single returning `then` and returning `else`; or
3. one single-returning `if` without `else`, followed by `return expression`.

Every other function has a `TITAN_SOURCE_LOCAL` prototype in the header and one
hidden external definition in the owning generated C object. Inline addresses
may differ between translation units; no canonical out-of-line identity is
silently added.

The driver refuses to overwrite a non-generated reserved path, replaces a
banner-owned header, and removes a stale banner-owned header after the module
loses its last foreign function. It formats each checking header and a sibling
public-header stage with the required `clang-format` command and Titan's fixed
LLVM-based four-space style before preprocessing or atomic publication. A
formatter failure leaves an existing public header untouched. The header is a
source build artifact only. It is absent from serialized types, `.titan.meta`,
provider key sets, DSO/archive publication, Lua shims, the installed SDK, and
standard-image transactions.

## Target-directed C allocation

### No initializer-less declarations

Every local declaration now requires `= ...`, including C aggregates and
arrays. There is no special `local x: c.T` or `local x: c.T[N]` zero-initializer
production. Zeroed automatic storage is requested explicitly with `.new()` or
`.new_array(...)`.

Source `c.T[N]` and `c.T[]` spellings exist only as the written target of an
initialized local allocation declaration. They are not general first-class
Titan type forms. `T[N]` is a real fixed C array; `T[]` is lowered to an
uncounted borrowed `T *` view.

### Selection happens at the direct local sink

The checker freezes one allocation plan while checking a direct constructor
call delivered to a newly declared function local. Code generation consumes
that plan and never rediscovers storage from endpoint tags. Module variables,
returns, call arguments, assignments to existing variables, nested expressions,
and discarded calls retain the ordinary owned result.

For an ordinary complete non-GC-bearing C struct or union `T`, `.new()` follows
this matrix:

| Direct local | Storage and local type |
| --- | --- |
| `local x = T.new()` | zeroed automatic `T` |
| `local x: T = T.new()` | zeroed automatic `T` |
| `local x: owned *T = T.new()` | zeroed owner userdata |
| `local x: *T = T.new()` | anonymous owner userdata plus a borrowed payload pointer; the hidden owner is rooted for the frame |
| non-direct-local context | `owned *T` |

Automatic scalar/pointer/enum allocation is not inferred: the automatic-object
case is specifically a struct/union aggregate. Existing allocation eligibility
still rejects `void`, direct C functions, incomplete objects, nested owners, and
automatic aggregates that contain GC-bearing storage. A C array typedef cannot
be an owned payload or use `.new()`, but a positive-literal `.new_array(N)` may
use an imported array typedef as an element when the direct sink selects nested
fixed automatic storage.

For non-FAM `T.new_array(count)`:

| Direct local | Storage and local type |
| --- | --- |
| inferred positive integer literal `N` | zeroed automatic `T[N]` |
| written `T[N]` | automatic array only when the positive extent and literal allocation count match |
| written `T[]` or `*T`, positive literal `N` | borrowed pointer over zeroed automatic `T[N]` backing |
| written `T[]` or `*T`, dynamic/zero count | borrowed pointer over hidden owned backing |
| written `owned T[]` | owned userdata for every count |
| inferred dynamic/zero count or non-direct-local context | `owned T[]` |

“Compile-time count” means a source integer literal. A fixed extent must be
positive. The borrowed `T[]` target intentionally carries no count: it is a raw
pointer view, so `#view` is unavailable and indexing has raw-pointer bounds
semantics. The backing only supplies lifetime. This avoids creating a second
counted owner type.

Automatic aggregate/array storage has ordinary C block lifetime and no escape
analysis. A pointer can dangle after its block/frame. A hidden owned backing is
rooted for the containing function frame, but returning its borrowed pointer
still loses ownership. Use an explicit `owned` target whenever storage must
escape.

A matching automatic struct/union can coerce to `owned *T`; a matching fixed
array can coerce to `owned T[]`. The conversion allocates and roots a userdata,
copies the complete object representation, and then publishes the owner. It is
one direct checker-owned allocation/copy operation, not subtyping and not a
structural conversion that lifts through Option or containers.

### Flexible-array-member structs

For a complete C struct `T` whose final field is `E field[]`:

```titan
local automatic = T.new(8)              -- literal count: extended stack object
local owned: owned *T = T.new(count)     -- GC-owned extended object
```

`T.new(fam_count)` is the only FAM constructor. `T.new()` has the wrong arity,
and **`T.new_array` is unavailable for a FAM struct**. Titan therefore never
pretends that multiple variably extended objects form an ISO C array or invents
a custom outer stride.

A direct inferred/by-value local with a nonnegative integer literal gets aligned
automatic backing. An explicit owner, an explicit `*T`, a dynamic count, or a
non-direct-local context uses one owner userdata (the pointer target receives a
borrowed pointer to that hidden owner). Both forms zero the complete extent. The
target C compiler determines the byte layout:

```text
extent = max(sizeof(T), offsetof(T, field) + count * sizeof(E))
```

Owned allocation evaluates the count once, rejects a negative count, and checks
addition/multiplication overflow before `luaS_newudata`. One private integer
uservalue stores the logical FAM count; payload bytes alone are not used to
infer it. Automatic literal storage records the same count in its checker plan.

While that provenance is intact, `owner.field[i]` and an automatic FAM local's
`field[i]` are 0-based and bounds-checked, and `#owner.field`/`#local.field`
return the logical count. Converting the owner/local to raw `T *` erases the
count. A FAM field reached only through that raw pointer remains an unsized C
array: it has no `#` and cannot use the count-aware indexing path.

Automatic FAM byte backing participates in the same volatile full-extent spill
and reload protocol as other automatic aggregates across ordinary Titan
`catch`/`finally` longjmps. Foreign functions themselves have no Titan
error-recovery path.

## Standard-library callback migration

The standard library now dogfoods the source feature rather than carrying C
callback shims.

* `titan.coroutine` defines `coro_entry_trampoline` as a foreign function and
  stores it directly in `mco_desc.func`. `minicoro.c` remains only as the one
  `MINICORO_IMPL` translation unit and the translation-unit-local fixed Lua
  tag comparator. `titan_coro_entry` and `titan/coro.h` are gone.
* The six `titan.uv` contributors define the thirteen exact libuv callbacks for
  filesystem, signal, process exit, DNS/connect/shutdown/connection,
  write/alloc/read/close/walk, and timers. `titan_uv.c` and `titan/uv.h` are
  gone. Address storage uses imported `sockaddr_storage`; argv storage uses the
  portable `titan_ffi_char_ptr` alias.
* `titan/http/native.titan` defines the eight synchronous llhttp callbacks.
  `titan_httpshim.{c,h}` and its standalone metadata-free object are gone;
  private `libtitan-llhttp.a` still contains exactly `llhttp.o`, `http.o`, and
  `api.o`.

`titan/ffi.h` supplies the narrow, typed inline Lua-internal bridges required by
those trusted callbacks: `lmacro_thvalue`, `lmacro_uvalue`,
`lmacro_clCvalue`, and `lmacro_pvalue`. General function-like macros remain
outside the FFI; the host C preprocessor expands the real Lua macros inside
these audited wrappers. The same header defines the small
`lua_totvalue`, `lua_pushtvalue`, `lua_togco`, and `titan_newthread` bridges as
`static inline`; they no longer require out-of-line runtime symbols.

Every libuv/HTTP foreign callback preserves the old reviewed owner protocol:
it recovers the exact already-traced owner and stored Titan callback closure,
obtains the Lua state, saves the stack top, casts the closure's native entry
through `foreign (...) -> ...`, invokes it with the exact callback shape, and
restores the top. The filesystem callback remains the
one-owner-argument protocol; its Titan continuation reads `uv_fs_get_result`.
No event-kind dispatcher or callback registry is introduced.

The installed runtime SDK archive now has exactly `titan.o` and
`minicoro.o`. Its namespaced installed header set is only `titan/ffi.h`
(alongside the top-level `minicoro.h` and `titan.h`; bundled
mode separately installs libuv headers). The standard provider's native payload
is `ltitanlib.o`, private LPegLabel, the selected libuv payload, private llhttp,
and the selected OpenSSL payload; there is no HTTP adapter object.

## ABI 0.23 boundary

The complete change advances the compiled-module ABI from 0.22 to 0.23. The
source syntax and local C types are not serialized, but two native contracts do
change:

1. generated standard objects now define their source foreign callbacks while
   the former runtime/HTTP callback symbols and `titan_uv.o` are absent; and
2. top-level ordinary/local/foreign function entry families use the
   `_\u2133_` member separator rather than the old ambiguous/private split.

An ABI-0.22 object or provider must therefore not be paired with the ABI-0.23
runtime or generated objects. `TITAN_VER`, `_0_23`, `TITAN_PATH_0_23`,
`lib/titan/0.23`, `share/titan/0.23`, and `stdlib_0_23` advance together.
Versioned 0.22 state is preserved, never migrated, cleaned, or treated as an
active-layout predecessor.

The generated foreign header and source collaboration view do not add metadata
keys or module-state slots. The standard provider still has eighteen logical
keys and nineteen DSO openers including bare `luaopen_titan`.

## Explicit non-goals

* no ordinary Titan-function/closure adapter to an arbitrary C callback ABI;
  write a restricted foreign function instead;
* no adopted/external ownership or finalizer model;
* no generic function-like C macro inference;
* no FAM `new_array`, custom-stride FAM collection, or count recovery from a raw
  pointer;
* no escape analysis or arbitrary stack-allocation size cap;
* no serialized C/foreign types or generated-header binary interface; and
* no ABI migration or compatibility callback object.

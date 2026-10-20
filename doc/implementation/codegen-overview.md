# Code generator: overview

The small `titan-compiler/coder.lua` facade eagerly assembles the code
generator slices under `titan-compiler/coder/`. `core.lua` owns their shared
private lexical environment and generation policy; implementation helper names
remain there rather than entering Lua's global namespace. The other modules
group native names, value and boundary lowering, flow analysis, Interfaces, numerics,
statements, calls, expressions, declarations, module artifacts, and final
generation. The facade exposes the two driver operations
`generate_foreign_header` and:

```lua
coder.generate(modname, ast, static_deps, abi[, emit_line_directives])
    --> string (one C translation unit), direct-native-reference set
```

where `modname` is the dot-separated module name, `ast` is the module's
AST *after* `checker.check` has decorated and rewritten it, and
`static_deps` is the driver's finalized direct-native name set. It contains
every source module compiled into the invocation plus every logical module
physically carried by a selected static provider; imports selected from DSOs
are absent. `abi` is the required compiled-module ABI string;
`emit_line_directives` defaults to true when omitted. `titanc` passes the
resolver context's
`native_static_names`, after provenance and producer-binding constraints have
been finalized, to every source module's code-generation pass. The return
value is the complete text of one C translation unit. For a
[folder module](folder-modules.md), `ast` is the same dense root list as for a
flat module, assembled from independently parsed files and checked once; the
checker may visit declarations in dependency stages, but it never rearranges
this list. The coder therefore still observes the logical source order that
defines interface members, module slots, module-variable initialization, and
emission; it has no source-unit node or contributor context. The driver
(`driver.compile`) writes the result next to the canonical flat source or
folder main, optionally invokes the configured `clang-format` when
`--pretty-print` is selected, then performs ordinary `#line` normalization or
[coverage marker conversion](native-coverage.md), and invokes
the system C compiler
([driver and toolchain](driver.md)). One consequence of the checker's
rewriting matters constantly here: every representation-changing implicit
conversion is an annotated `Ast.ExpCast`, same-representation and open
adjustments remain on their checked consumers, every statically demanded
extra result is an `Ast.ExpExtra`, and finite/open expression-list demand is
recorded on the enclosing sink. The coder therefore lowers checker-owned
plans instead of inventing conversions or arity rules of its own
([the type checker](checker.md)). This chapter covers the shape
of the output and the protocols it implements; value-level details are in
[values and the GC](values-and-gc.md), per-construct translations in
[code generator: constructs](codegen-constructs.md), the normative strict and
dynamic policies in
[type relations and boundary plans](type-relations-and-boundaries.md), and Array
representation and lowering in [Dense Arrays](dense-arrays.md).

One no-`main` CLI invocation may link several such translation units into a
single [multi-module provider](multi-module-libraries.md). The coder still runs
once per logical module; it never sees a provider AST or emits aggregate
metadata.

## No C AST: templates, `util.render`, and `clang-format`

The coder builds no intermediate representation of the C program. Each
code-generation function returns C source as a Lua string, produced by
substituting into literal templates with `util.render` (`util.lua`).
Placeholders are `$VAR` or `${VAR}`; substitution is **recursive** (the
replacement text is itself rendered against the same table, so templates
nest freely); a placeholder missing from the substitution table is a hard
error — `Internal compiler error: missing template variable <name>` plus
the offending template — unless the optional `ignore_missing` flag is
passed. The coder passes it in exactly one place, `codethrow`, whose
`luaL_error` templates deliberately leave placeholders such as `$FILE`,
`$LINE` and `$COL` for an enclosing render to fill.

Because there is no C AST, template output is raw but must already be valid C.
The default driver persists that output without a presentation pass; it still
removes blank physical lines after `#line` directives before native
compilation, consumer probing, or header publication. `titanc --pretty-print`
additionally runs the configured `CLANG_FORMAT` command (default
`clang-format`) on every generated `.c` and staged `.titan.h`. It passes an
explicit LLVM-based four-space style with include sorting disabled and never
inherits an arbitrary project's `.clang-format`.
Disabling sorting is semantic preservation rather than aesthetics, because the
generator deliberately orders direct, supplemental, and source-foreign
includes. An opted-in formatter failure is a compiler error; a public header
remains untouched, while a generated `.c` remains available as a diagnostic
artifact. See [Driver and toolchain](driver.md#optional-clang-format-generated-source-formatting).

## Anatomy of a generated translation unit

`coder.generate` assembles the unit from a fixed preamble template plus a
`code` list filled by kind-filtered passes over the top levels (imports,
variables and records first; functions second). Each whole-root-list allocation
and emission walk uses `ipairs`, preserving relative dense
main/contributor order within those categories; maps whose order has no
semantic effect may still use `pairs`. The pieces appear in this order:

1. **Preamble includes**: `<stdlib.h>`, `<string.h>`, `<math.h>`, then
   Lua's **internal** headers (`lobject.h`, `ltable.h`, `lvm.h`, `lgc.h`,
   `lstring.h`, `lfunc.h`, `ldo.h`, `ltm.h`, plus `luaconf.h` and
   `lauxlib.h`) and `titan.h` from `titan-runtime/`. The internal headers
   are the point: generated code manipulates `TValue`s, tables and the
   Lua stack directly instead of going through the Lua C API — which is
   what makes Titan fast and ties each compiler release to one Lua
   version (currently 5.5.1).
2. **Foreign `#include`s** (`$FOREIGNIMPORTS`): one per `foreign import`
   — quoted includes for absolute paths and local relative headers, angle
   includes for compiler-provided and system headers ([FFI
   internals](ffi-internals.md)) — followed by an `#ifdef __clang__` block
   silencing two warnings.
3. **Cross-module declarations** (`$INCLUDES`, filled by
   `init_data_from_other_modules`): `extern` or `static`-function-pointer
   declarations for every imported function actually called. (A record's
   type identity is its metatable, cached per-Lua-state in a `_mod` user
   value rather than a C static, so an external record needs no
   per-translation-unit tag declaration — see the wiring section below.)
4. **Forward signatures** (`$SIGS`): the native-convention prototype of
   every function in this module, plus
   `extern Udata *<dep>_init(lua_State *L);` per static import.
5. **Record support**: per record (from `coderecorddec`), the separated
   nominal `meta_index`/`meta_newindex` metamethod entries serving field access
   from Lua ([Lua interop internals](lua-interop-internals.md)). A
   record's type identity is its metatable (cached per-Lua-state in a
   `_mod` user value), so there is no per-record C tag static to declare
   up front. Generated native payload declarations, exact numeric Option
   carriers, and public-prefix physical plans are described in
   [Native nominal storage](nominal-storage.md).
6. **Function bodies**: native-convention bodies plus the required stack
   entries. Ordinary functions and statics that become values have coercive
   genuine-Lua and strict Titan-generic entries. Methods have their ordinary
   Lua method entry plus the native/Lua/strict bound-value trampolines. A local
   ordinary function needs the two stack entries only when it becomes a
   first-class value.
7. **Module-global metamethods**: if the module exports anything, one
   `meta_index`/`meta_newindex` pair in the separated module callable family
   serves all members — variables, functions
   and public record namespaces — through the metatable installed on the module
   `Udata`.
8. **`<prefix>_abi`**, **`<prefix>_types`**, **`<prefix>_layouts`**,
   **`<prefix>_init`**, **`luaopen_<prefix>`**: the
   module-protocol functions, described below. One final DSO may contain this
   complete set for several translation units; every set remains independent.

### Mixed-source `#line` attribution

One folder-module C file contains functions and statements originating in
several Titan files. `emitline(node)` therefore retains its existing per-node
design: it C-quotes `node.loc.filename` and emits `#line` at safe physical-line
sites such as function entries, statements, calls, `raise`, and related throw
paths. Code generation does not install one directive for the whole
translation unit or stamp expression fragments that may be embedded mid-line.
The directive naturally changes filenames as root nodes and nested bodies from
different contributors are emitted, so compiler diagnostics, DWARF, and
libbacktrace frames identify the actual source file and line.

When `coder.generate` receives a false line-directive policy, `emitline`
returns no directives for that generation. The public
`--no-line-directives` flag and `TITAN_NO_LINE_DIRECTIVES=1` build setting use
this path so native diagnostics expose physical generated-C coordinates. The
policy is reset at the start of every generation, preventing state from
leaking between compiler calls in the same Lua process.
The tradeoff is deliberate: traceback reconstruction uses Titan-attributed
debug filenames to retain ordinary native Titan frames, so this diagnostic
mode can omit them from logical traces even though the symbol-to-display-name
registry is unchanged.

A trimmed but real example (elisions marked `...`) — this module:

```titan
-- counter.titan
x = 1
function inc(n: integer): integer
    return n + x
end
```

generates:

```c
#include <stdlib.h>
...                /* C library and Lua internal headers, titan.h, pragmas */

lua_Integer counter_\u2133_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n);

lua_Integer counter_\u2133_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n) {
    {
        return (_param_n+ ivalue(&_mod->uv[0].uv));
    }
}

static int counter_\u2133_inc_titanentry_lua(lua_State *L) {
    ...    /* argument count adjustment, error handler, dynamic argument plan */
    lua_Integer res = counter_\u2133_inc_titan(L, _mod, _fn, _param_1);
    setivalue(s2v(_firstret), res);
    ...
}

static int counter_\u2133_inc_titanentry_strict(lua_State *L) {
    ...    /* hidden original closure plus strict argument guards */
}

static int __index(lua_State *L) { ... }    /* module metatable: member read  */
static int __newindex(lua_State *L) { ... } /* module metatable: member write */
int counter_abi(lua_State* L) { ... }       /* returns TITAN_ABI_VERSION */
int counter_types(lua_State* L) { ... }     /* serialized interface, below  */

Udata *counter_init(lua_State *L) { ... }

int luaopen_counter(lua_State *L) {
    titan_invalidate_backtrace_state(L);
    Udata *mod = counter_init(L);
    setuvalue(L, s2v(L->top.p), mod);   /* require returns the module Udata */
    L->top.p++;
    return 1;
}
```

For a branded exact-tag mismatch, caller-side `codevaluecall` applies the
strict result actions after the declaration entry or wrapper relay has boxed
the native results. An exactly tagged realized wrapper instead executes its
frozen result actions inside the target-native adapter.

Module protocol names come from `mangle_qn` (`coder/names.lua`), which
replaces `.`
and `-` with `_`. The driver has already restricted every logical component to
`[A-Za-z_][A-Za-z0-9_-]*`, so this does not admit arbitrary path or template
bytes. Module `foo.bar` yields `foo_bar_init`, `foo_bar_abi`, `foo_bar_types`,
`foo_bar_layouts`, and `luaopen_foo_bar`.

Callable names have two structural boundaries. `_function_prefix`
separates the flattened module prefix from the remaining callable with the C99
UCN `_\u2133_` (U+2133 SCRIPT CAPITAL M). A top-level function `f` therefore
becomes `foo_bar_\u2133_f_titan` / `..._titanentry_lua` /
`..._titanentry_strict`; a source `foreign function f` owns only the first
spelling. `_nominal_function_prefix` then separates a record, union, or
Interface owner from its member with `_\u2131_` (U+2131 SCRIPT CAPITAL F):
`foo_bar_\u2133_Point_\u2131_move_titanmethod`. Statics, synthesized record
`new` and union variants, ordinary methods, bound native/Lua/strict entries,
and Interface bound entries all use that hierarchy. The nominal metamethods
are synthetic `meta_index` and `meta_newindex` members in the same family;
module userdata metamethods use only the module boundary.

Neither U+2133 nor U+2131 can occur in Titan's ASCII identifier alphabet, so
the tuple boundaries remain injective even when source names contain
underscores. Generated C retains both UCN spellings. `_linkage_symbol_name`
converts them to UTF-8 `ℳ` and `ℱ` for object-file, DWARF, libbacktrace, and
native-tool comparisons. An unbound method appends `_titanmethod` /
`_titanentry_luamethod`; its first-class bound value appends `_boundmethod`,
`_titanentry_boundlua`, and `_titanentry_boundstrict`. A static appends
`_titanstatic`, `_titanentry_luastatic`, and `_titanentry_strictstatic`.

`coder.external_symbols` inventories the non-file-local subset of these names
plus each module protocol. Library-mode orchestration compares that exact set
before code generation, retaining flattened module-prefix and cross-family
protocol collision checks; it does not wait for the linker to diagnose
duplicate definitions.

### Failure-only ASan generated-C mapping

The Linux sanitizer workflow keeps normal Titan attribution on the code that
it executes, but preserves an exact second view for a failed AddressSanitizer
report. When the opt-in diagnostic snapshot is configured, the shared stdlib
publication recipe copies the sanitized checkout `titan.so`, together with
every matching generated `.c`/`.o` translation-unit pair from the source output
paths used for that link, after `titanc` has completed and before publication
or later tests can replace those outputs. The snapshot also records the
canonical installed provider path and source display root plus the NUL-delimited
argv returned by
`driver.generated_compile_prefix()`. It therefore describes the precise
provider and input objects from which that provider was linked, not a later
rebuild.

Each sanitizer gate runs once while its original combined output is captured.
Only the workflow's failure-only diagnostic step reads those logs and the
snapshot; it does not rerun the failing test, regenerate the standard library,
or execute a second provider. For a numbered frame from the original ASan
output, the mapper requires the relocation-safe
`(<canonical-provider>+<module-offset>)` pair and, when the provider carries a
BuildId, verifies the frame's BuildId against it. It locates the containing
provider `.text` symbol, retains the byte delta within that function, and finds
the one saved translation-unit object that defines the same nonempty function
symbol.

The mapper then builds one diagnostic shadow object on demand for that
translation unit. It replaces each generated `#line` directive with a blank
line, preserving every physical line number, and compiles that saved C at an
exact private shadow pathname with the captured compile-prefix argv plus the
shadow input and output operands. The shadow is not linked or executed. Before
using its DWARF,
the mapper requires the original and shadow target functions' complete byte
ranges within `.text` to be identical; it also verifies the provider, original
object, and shadow function sizes, the original/shadow addresses, unique symbol
ownership, and `.text` section membership. Other functions may carry different
sanitizer source-location metadata without weakening this instruction-level
proof. Only then does it apply the saved provider byte delta to the shadow
symbol, ask `addr2line` to resolve that offset specifically within the
relocatable object's `.text` section, require that it return the exact private
shadow pathname, and print numbered context from the line-identical saved
generated C under its original pathname. Missing module offsets, a
required BuildId, symbol mismatches, overlapping or aliased functions, changed
target code bytes, and other incomplete evidence make that frame unavailable
rather than producing a speculative mapping.

This recovery path deliberately leaves ordinary per-node `#line` directives
enabled during the sanitizer run. Those directives preserve the logical Titan
frames required by traceback tests and normal diagnostics; the verified shadow
recovers physical generated-C lines after a failure without perturbing the
failure or requiring it to reproduce. `TITAN_NO_LINE_DIRECTIVES=1` remains an
isolated reproduction aid, not the complete sanitizer-suite policy.

## Three entry roles per first-class Titan function

Every first-class Titan function has three entry roles:

1. the typed native-convention function used by static/direct and exact-tag
   first-class calls;
2. a coercive Lua-stack entry used when genuine Lua calls the source closure;
   and
3. a strict Titan-generic Lua-stack entry used after a branded exact-tag
   mismatch.

The two stack entries share one generation template but apply different
checker-produced policies. The canonical **source** closure's public
`CClosure.f` is the coercive entry; its declaration-specific strict entry is a
light C function stored in the final upvalue. A local function still has only
the native body when it is never referenced as a value. Once a canonical source
value is required, the coder emits both stack entries and the same closure
layout without exporting it through the module member map. Unbound methods use
their native/Lua method entries; their first-class bound values receive native,
Lua, and strict bound trampolines.

A realized non-exact callable adjustment reuses these roles rather than adding
a fourth ABI entry: its native pointer names a target adapter, its
`CClosure.f` copies the immediate source's coercive entry, and its final upvalue
names a consumer-local strict target relay. The guarded constructor checks only
a non-null `CClosure`, `5 <= nupvalues < MAXUPVAL`, the exact lightuserdata tag
in slot 1, and the lightuserdata brand in slot 3; the remaining private layout
is trusted. It allocates the final closure with `luaF_newCclosure`, initializes
fresh-white upvalues with `setobj2n`/`setpvalue`/`setclCvalue`/`setfvalue`, and
publishes directly to the assigned result root—never through transient
`lua_pushcclosure` stack assembly. A synthesized native adapter whose frozen
action graph can allocate polls at function entry before stack reservation or
raw stack pointers; the constructor itself never polls between allocation and
publication. See
[Closure adjustment wrappers](closure-adjustment-wrappers.md).

### Cross-state closure transfer metadata

`coder/closure_transfer.lua` emits one immutable `TitanTransferModule` manifest
per generated module. The existing native-symbol resolver returns it for
`TITAN_TRANSFER_MANIFEST_SYMBOL`; ordinary closure allocation and invocation
perform no additional lookup and keep their existing upvalue layout. Each
first-class source function, lambda, bound method, and realized callable
adapter has an entry containing its native/strict lookup key, immediate capture
count, and generated projection/restoration functions. The manifest also
publishes one `TitanTransferCodec` per generated record or union codec
(`coder/nominal_codec.lua`): its qualified name, kind, and generated encode and
decode functions, emitted next to the nominal's other storage helpers. The
nominal's metatable registration binds `TITAN_MT_CODEC` to that entry; see
[generated nominal codecs](protobuf-library.md#generated-nominal-codecs). A
referenced local function has the same transfer capability
as an exported function. Captured nominals still follow the public protobuf or
custom-record transfer policy; local nominal types remain ineligible.

Projection visits actual capture values, never module userdata or a mutable
cell's bytes as if they were a Lua value. The checker records capture conversion
plans and refreshes them after generic erasure. Generated callbacks use the
existing `box_read`/`newbox`/`box_write` policies: scalar cells contain an inline
native payload, while GC-bearing cells contain a traced uservalue. Native
integer bits and long-double text use the same exact projection representation
as reflected native fields. One generated function projects **all** immediate
semantic captures onto the source stack before custom hooks run. The source
closure and projected values remain rooted while ordinary Titan code converts
and serializes them. Owning-state foreign functions in `titan.transfer` discover
entries, project captures, and invoke generated restoration; for closures
`transfer.h` only declares the immutable manifest layout. Capture snapshots use
no native recursive serializer, allocation arena, or source identity map
(nominal captures reach generated codecs only through their protobuf root).
Generated code rejects Lua-managed `Udata *`
before native-pointer projection, including typedef spellings and present
optional pointers; an absent optional projects and reconstructs as nil. This
guard prevents the trusted GC-bearing pointer representation from becoming a
borrowed lightuserdata address. Unsupported reconstruction conversions also
fail during projection, before the packet crosses the boundary.

Destination reconstruction calls the named loader directly from
`LUA_PRELOAD_TABLE` and roots its returned module. The ordinary generated
initializer already memoizes that module. The foreign helper obtains the returned
module's manifest through its own `TitanModuleData.symbols` and matches the
incoming token by pointer equality against entry addresses **before
dereferencing it**. Invalid tokens and different physical providers are
rejected before decoding captures or invoking reconstruction hooks. No
initializer pointer travels with the packet.

One generated restore function consumes a contiguous semantic capture run. It
converts and roots every internal slot, allocating a fresh box for each mutable
capture with `newbox`/`box_write`, before allocating the final closure. The
fresh-white closure receives its complete header, slots, and strict trailer
without intervening allocation, then becomes rooted before the allocation debt
check. Function tags come from the destination module's canonical per-state
caches. There is no per-capture callback, scratch slot table, boxedness bitmap,
or shared-cell reconstruction.

An adjustment entry projects only its immediate source closure. Once that
source has been reconstructed, the generated adapter callback repeats the
ordinary prefix-copy construction, replacing module/tag/native/strict entries
with the destination adapter's values. This preserves the copied source capture
prefix, source coercive entry, and penultimate source link without
serializing private wrapper layout twice. Ordinary Titan transfer code owns
active closure-cycle detection and snapshot conversion; nested packets already
contain opaque bytes. See [Lua-state transfers](lua-library.md)
and [Receiver ownership](libuv-runtime.md#cross-state-receiver-ownership).

Custom and ordinary nominal packets carry both their qualified nominal name
and actual declaring-module name recovered through `TITAN_MT_MOD`; nested types
and folder modules do not require name splitting. A captured record is
reconstructed through its hook or protobuf policy. A captured `TransferValue`
is flagged so reconstruction retains the union instead of unwrapping it.

Titan's normal native loader and generated Lua shims retain provider images for
the process lifetime, so a transferred closure remains valid after its source
Lua state closes. Arbitrary manual native-library loading keeps the existing
caller-owned code-lifetime contract, as for raw C functions and native preload
snapshots. The transfer packet does not pin origin Lua objects or add a separate
OS-library lifetime protocol.

### The Titan-native function and its calling convention

The authoritative statement is the comment above `codefuncdec` in
`coder/declarations.lua`:

```
-- Titan calling convention:
--     first parameter is a lua_State*; remaining inputs use their actual native
--     C types. The caller never publishes tracing-only Lua-stack copies of those
--     arguments. A callee creates a separate local home only when mutation or
--     setjmp spilling requires one. The function returns its first result
--     directly and writes later results through out parameters. A native caller
--     roots each GC-bearing result immediately after return, before later work
--     can collect it; returning itself cannot run the collector.
```

The signature shape, produced by `function_sig`:

```c
RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, [Udata *self,]
          <ctype(param_1)>, ..., <ctype(param_n)>,
          [TitanVargX *_varargs, int _start,]
          <ctype(ret_2)> *_outparam_2, ..., <ctype(ret_m)> *_outparam_m,
          [TitanVargY *_flexout, int _flexwant]);
```

`RETTYPE` is `ctype(rettypes[1])` — the unboxed C type of the first
return value (`lua_Integer`, `TString*`, `Table*`, `TValue`, `Udata*`,
…; full map in [values and the GC](values-and-gc.md)); a function
returning only `nil` returns `int` and ends with `return 0;`; a flex-only
function returns C `void` and writes its caller-owned descriptor. The input
vararg pair, when present, precedes fixed result out-pointers. The flexible
output pair, when present, comes last. `_mod` is
the callee's **own** module `Udata`; a cross-module caller passes it from
one of its user values. `_fn` is the **callee's own closure** — the
`CClosure` of the function value being invoked, whose `upvalue[4..]` hold
its captured variables; it is what a closure body reads its captures
through (see [closures and captured variables](#closures-and-captured-variables)).
It comes **immediately after `_mod` and before the method `self`**, and
*every* Titan function takes it even when the body never reads it: the
fast value-call path dispatches purely on the function-type tag, so all
native entries of a given `Type.Function` must share one ABI. This type is
exclusively a boxed Titan/Lua callable; its third constructor
position remains reserved `false`, not C variadicity. Its value at a call site
depends on the
path:

* **`NULL`** on a static direct call (`codecall`) — a top-level
  function/method/static reached by name has no closure to pass;
* **the callee value itself** (`_vc_callee`) on the fast value-call path
  (`codevaluecall`);
* **`clCvalue(s2v(func))`** in either Lua-stack entry (directly for the
  genuine-Lua entry and through the strict entry's hidden carrier), which then derives
  `_mod = uvalue(&_fn->upvalue[0])` (the module value stored in the
  closure's upvalue 0 is now a `Udata`, read with `uvalue`, not
  `clCvalue`).

`TitanVargX` and `TitanVargY` stand for the element-specific descriptor
types (`TitanVargInteger`, `TitanVargString`, and so on); input and output
tails use the same descriptor family even when their element types differ.

The `Udata *self` slot exists only for methods (`Type.Method`) and is
named `__self__` in the generated body — `self` is a record, and a record
is a `Udata`. Return values 2..m are written through out-pointers
following the declared parameters. Real signatures from a generated
module:

```c
TString*    packtest_\u2133_Point_\u2131_getname_titanmethod(lua_State *L, Udata *_mod, CClosure *_fn, Udata* __self__);
lua_Integer packtest_\u2133_two_titan(lua_State *L, Udata *_mod, CClosure *_fn, TString* *_outparam_2);
void        packtest_\u2133_strings_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                          TitanVargString *_flexout, int _flexwant);
```

A Titan-to-Titan call is therefore an ordinary C call — no `CallInfo`, and no
boxing of integers, floats, or booleans. It evaluates inputs in lexical order.
When later setup is effectful, `coder._freeze_code` freezes the first-class
callee/receiver and the affected fixed or static/open-vararg inputs in untraced
C temporaries; a pure trailing suffix may remain direct C expressions. The call
never publishes tracing-only Lua-stack copies of native inputs. Fresh values
retain their initial allocation or prior native-result roots, while established
values retain their semantic module/record/container/local home or an upstream
Lua VM argument slot. Static and forwarded input-vararg payloads merely borrow
that provenance; their raw descriptors and C buffers are never roots. A callee
creates a separate parameter home only when assignment or setjmp spilling makes
it a real local-storage requirement.

Lua 5.5's non-moving GC preserves the heap addresses of reachable strings,
tables, userdata, and closures, but stack growth can relocate the stack array
and invalidate raw `StkId`/`TValue *` pointers. Generated code therefore saves
stack offsets and rebases after every operation that can really move the stack
and after every native call, even when the call had no input slots.

Native fixed results initially occupy raw ABI C holders. Returning cannot run
the collector, but a transitive callee's allocation root is above the restored
caller top. After rebasing, the caller performs any nonallocating raw-to-visible
projection and immediately publishes every live GC-bearing fixed source result
into its result root, including an identity result, before any later allocating
work. An ordinary open GC-bearing result similarly copies its complete live
prefix into a parallel traced range before conversion and until its sink
consumes it. Callable and Interface adapters use the same source rule; they add
destination roots only in branches that freshly allocate converted wrappers.
`TitanVargX` descriptors and raw C arrays never become roots.

The Lua-stack and branded-strict slow paths are intentionally different: they
push the callee/carrier and every actual argument because those slots are the
Lua VM calling convention itself. Native callable/Interface adapters have an
empty input-source root inventory; they do not mistake those VM transport slots
or native C inputs for call-activation roots.

### Named direct calls and lexical evaluation order

The checker has already normalized an eligible named call to a dense
formal-order `ArgsFunc` or `ArgsMethod`, but leaves `_named_arg_order` with the
formal indexes of explicit expressions in lexical order. `codecall` sends that
pair through `named_ordered_call_args`: it generates and immediately freezes
each explicit expression in an untraced C temporary in lexical order, then does
the same for synthetic nil omissions, and finally emits the unchanged
formal-order native argument list. For a method, the receiver is frozen once
before this sequence. This C-only materialization preserves effects before
formal reordering without publishing receiver/argument roots.

Positional direct calls follow the same checked adjustment plan. Every
explicit argument is evaluated once in lexical order; surplus expressions are
evaluated only for effect, while only the fixed prefix and any accepted input
tail reach the native call. On the result side `codecall` allocates fixed
holders required by the declared ABI, publishes only the consumer-visible
projection, and, for a flexible producer, allocates a typed caller-owned buffer
sized to the finite demand or to the bounded open budget.

Direct foreign calls use the parallel branch in `codeforeigncall`, which
requires the authoritative `Type.CFunction` and emits the bare C declaration;
there is no projected `Type.Function` fallback. Calls through
`CPointer(CFunction)` instead use `codecfunctionptrcall`, materializing and
null-checking the pointer once. Each named direct-call expression is converted
and assigned to a target-typed C temporary in lexical order; the call prints
those temporaries in formal order. Mutable GC-bearing out-parameter anchors are
still refreshed after the C call. Neither C branch emits closure tags, brands,
strict relays, adjustment wrappers, or a runtime name table, and a named call
never reaches `codevaluecall`.
See [named-argument internals](named-arguments.md).

### Calling function values (`codevaluecall`)

Calling a first-class function value is the one Titan-to-Titan call form
that may deliberately fall back to Lua's ordinary call machinery. The
callee expression has static type `Type.Function`, but its runtime value
is a boxed `TValue`: it may be a Titan `CClosure`, a Lua closure, a Lua C
function, or an object with a `__call` metamethod. `codevaluecall`
therefore emits three branches.

A finite non-exact Function adjustment is lowered before this call dispatch as
an `Ast.ExpCast`. Its operand is frozen once in C while its existing traced
provenance stays live; the guarded constructor may produce a fresh target-tagged CClosure whose
native pointer is the frozen adapter, or preserve the carrier unchanged.
Open-run callable elements use the same helper when their shared adjustment is
consumed. Wrapper construction is an allocating/raising expression effect, not
an inferred branch of `codevaluecall`, but direct `luaF_newCclosure`
construction does not relocate the Lua stack.

The **exact fast path** is tested first and marked `TITAN_LIKELY`. It requires
a `CClosure` with at least the five minimum Titan upvalues and raw pointer-bit
equality between upvalue 1 and the tag for the callee expression's static
type:

```c
if (TITAN_LIKELY(runtime_tag == <function-type tag>)) {
    ...
}
```

Those tags are canonical pointers cached in the current module native payload.
`function_type_tag` allocates the cache entry; initialization publishes or
recovers its immutable candidate through the Lua registry so
source-linked and `.so`-loaded modules agree on the pointer for the same exact
type. All shapes use `types.runtime_identity(ftype)`, which retains nested
declarator qualifiers and adds C declaration origins to header-dependent shapes.
The same C declaration shares identity across modules. Exact
pointer equality is sufficient evidence for the private Titan layout under
the same trusted-debug/C-API invariant as the closure upvalues themselves; the
hot branch neither queries the Lua registry nor rechecks the module, native
pointer, brand, and strict-trailer slots. It first requires the five-upvalue
minimum and reads the tag's raw pointer bits, so no `ttis*` discriminator is
needed on this trusted private slot.

Matching the tag is stricter than gradual consistency. A Titan
`function (value): (integer)` viewed as `function (integer): (integer)` through a dynamic
`value` round trip has no statically known source Function edge, so its tag does
not match and it cannot use this branch. By contrast, a direct checker-approved
non-exact `A -> B` cast may conditionally realize a closure tagged B; that
wrapper *does* enter this branch and its upvalue-2 pointer invokes the target
adapter.

Once the fast predicate holds, the call is again an unboxed native call:
`_vc_callee = clCvalue(&fn)`, `_vc_mod =
uvalue(&_vc_callee->upvalue[0])`, and the native entry pointer in
`upvalue[2]` is cast to the exact `function_sig` typedef and called with
`L`, `_vc_mod`, `_vc_callee`, the already-evaluated native arguments and
the usual out-parameters. Passing `_vc_callee` as `_fn` is what lets
anonymous closures and bound-method trampolines read their captured
upvalues while still using the same fast branch as top-level function
values.

Only after the exact comparison fails does the coder test the type-independent
closure brand in fixed `upvalue[3]`. The brand is the opaque, ABI-owned
64-bit pointer sentinel `TITAN_BRAND`; it is never
dereferenced. A C closure must have at least five upvalues before the coder
reads that slot. Raw equality is then enough to trust the rest of the private
layout: no registry access or other `ttis*` shape checks occur. An unrelated C
closure would need both the required upvalue count and the exact random
sentinel in the exact slot, making accidental classification astronomically
unlikely.

The branded exact-tag-mismatch path pushes the closure's trailing strict light
C function as the VM callee, then the original closure as one hidden first
argument, followed by the already evaluated ordinary arguments. For an
ordinary source closure, the declaration-specific strict entry validates that
carrier's header, trailer, coercive entry, and exact source tag; it does not
repeat the brand check. For a realized wrapper, the consumer-local relay
instead validates the target tag, native adapter/header shapes, brand-selected
carrier, and its own trailer, deliberately without requiring one source
`CClosure.f`. It invokes the target adapter with the wrapper as `_fn`.

Either strict entry recovers its authoritative module/native route, executes
strict guards for the known callable shape, and returns boxed results for the
call site's strict result actions. This path never calls the coercive
`CClosure.f`, so integral-float or truthiness conveniences cannot leak into a
Titan callable adjustment.

The **non-Titan path** is used for Lua closures, Lua light C functions,
foreign C closures, and `__call` objects. It pushes the boxed callee followed
by the already evaluated arguments onto the Lua stack with `setslot`. Values
returning into Titan consume the checker-attached `DynamicCoercionPlan` for
each expected result. Ordinary finite calls use
`luaD_callnoyield(L, restorestack(L, _vc_func), nresults)`. A generic producer
that is statically open at the call site uses `LUA_MULTRET`, measures the raw
result count, nil-fills any missing fixed prefix, converts the tail into the
same typed descriptor used by the exact path, and caps the retained run at
`TITAN_VARARG_MAX` (or copies only an inherited finite remainder). An open sink
over a fixed-only static callable remains an ordinary finite call.

Lua 5.5 encodes a finite VM result request in `CallInfo` with a maximum of
250. The checker rejects generic function-value sites whose finite visible
request exceeds that count. This is independent of Titan's 200-element
descriptor cap; direct native calls and statically open generic producers do
not use the finite VM field.

Every statically open generic producer uses `LUA_MULTRET`, including when an
enclosing flexible native entry has a finite `_flexwant`. The returned values
remain rooted on the Lua stack while the generic branch measures the raw count,
nil-pads a missing fixed prefix, converts the retained tail, and applies the
enclosing finite/open Titan budget. It then resets `L->top.p` to discard the
call frame and result slots. This is also where non-callable values fail
cleanly at runtime. A branded exact-tag mismatch (ordinary declaration entry or
wrapper relay) and a non-Titan Lua callable retain the same finite/open shape
machinery, but their strict versus dynamic element policies remain distinct.

Because the generic branch can grow and relocate the Lua stack,
`codevaluecall` marks the enclosing function as `uses_base_off`, saves stack
positions as offsets, and recomputes `_base = restorestack(L, _base_off)` after
every branch. Before branch selection the callee and arguments are only stable C
values; the exact Titan branch passes them directly. The branded-strict and Lua
branches push those same values because the pushed slots are their real VM call
frame. Native open runs are published before the branch joins; immediately after
convergence, each live fixed native result is projected and published into its
caller result slot. Generic results remain rooted in VM slots through conversion
and are then copied into the same caller destinations.

### The two Lua-stack entries

`genluaentry` emits one shared arity/tail/result/error-frame shell under two
policies.

The canonical source closure's `CClosure.f` is the **coercive genuine-Lua
entry**. A realized adjustment wrapper copies that same pointer rather than
advertising a target coercive entry. It pads missing fixed arguments with nil,
ignores fixed-function surplus or
collects an input tail, installs the Titan error handler, recovers `_fn` and
`_mod`, and consumes the checker-attached `DynamicCoercionPlan` for every
formal. It reserves the requested result slots, calls the native function, and
boxes results for Lua. Written `value as/is T`, record/module/Array Lua writes,
and this entry use the same target matrix.

The **strict Titan-generic entry** is a light C function stored in the final
upvalue. A canonical source closure stores its declaration-specific entry; a
wrapper stores its consumer-local target relay. `codevaluecall` pushes that
trailer as the callee and passes the closure as a hidden argument. Both exclude
the carrier from arity math and apply strict gradual actions rather than
dynamic coercions. The source entry validates its declaration tag and calls the
source body. The wrapper relay validates its target header/trailer and calls the
target adapter, which delegates to the immediate source closure.

Both policies share fixed/variadic arguments, finite/flexible result request,
stack relocation, and error-handler structure. The full generated anatomy and
boundary matrix are in
[Lua interop internals](lua-interop-internals.md) and
[Type relations and boundary plans](type-relations-and-boundaries.md).

## Closures and captured variables

An anonymous literal used directly as a call's callee instead follows the
[inline immediate-call path](immediate-functions.md): its source body becomes
a scoped block, so its closure and separate entries are omitted. The layout
below applies when a function value is materialized, including nested closures
that escape from an inline body.

An anonymous function ([closures](../language/closures.md)) is a source function
value just like a top-level reference — a `CClosure` whose `f` is the coercive
genuine-Lua entry, with a four-slot header, one upvalue per captured variable,
and the declaration's strict Titan-generic light C function in a final trailer
slot:

```
upvalue[0]     = _mod                  (the module Udata, captured lexically)
upvalue[1]     = function-type tag     (light userdata)
upvalue[2]     = native entry ptr      (light userdata)
upvalue[3]     = closure brand         (light userdata)
upvalue[4 + i] = captured variable i   (a box, or a copied value)
upvalue[4 + ncaptures] = strict entry  (light C function)
```

The trailer is found from the source closure's actual upvalue count; capture
indices therefore remain stable. The constant `4` separates the header from
the captures, and a closure body reaches capture *i* as
`_fn->upvalue[4 + i]`. A realized adjustment wrapper has a distinct layered
layout: it copies slots through the source's penultimate slot, replaces the tag
and native pointer, appends the immediate source closure as a traced
penultimate link, and installs the target relay last. Its copied captures stay
at the same indexes; see
[Wrapper layout](closure-adjustment-wrappers.md#wrapper-layout). The `_fn`
parameter (above) is exactly what makes this work: a top-level call passes
`NULL`, but a closure is always entered with `_fn` pointing at itself.

### The captured-variable box

A variable that is both **captured and assigned** (mutated by an inner
function) cannot be a plain C local — the inner closure must share one
mutable cell with the declarer and any sibling closures. The
representation is a **box** Udata copied into every capturing closure. A
non-GC value uses a zero-uservalue Udata with the raw C value in its payload.
A GC-bearing value uses a one-uservalue Udata with the boxed value in
`uv[0]`. The latter uses `luaC_barrierback` on mutation because userdata
traversal participates in `genlink`; the former contains no collectable edge
and needs no barrier. This avoids promoting every freshly stored loop value as
a CClosure forward barrier would.

A box is allocated and **immediately anchored** in a dedicated stack slot
before its initializer is stored into it, so there is never an unanchored-box
window. Installing the box pointer into the enclosing function closure uses
the ordinary closure forward barrier. A variable that is
captured-but-immutable, or mutated-but-not-captured, keeps its ordinary
representation; only the conjunction is boxed.

### Capture lists, lambda hoisting, transitive capture

The checker computes, for each `ExpFunction`, the ordered de-duplicated
list of enclosing-function declarations it captures (see
[the type checker](checker.md#closures-capture-analysis-and-lambda-inference)); the coder
turns that list into the `upvalue[4 + i]` slots in agreed order. At the
use site the coder allocates the exact closure with `luaF_newCclosure`, fills
the four header upvalues, captures, and strict-entry trailer directly while the
closure is white, then publishes it into its traced result slot before paying
the allocation's GC debt. No capture transits through `L->top`, and no barrier
is needed before publication. The post-publication collector poll may relocate
the Lua stack, so generated code restores `_base` from `_base_off` afterward.

Lua permits at most 255 C-closure upvalues. Five structural source slots leave
**250 captures**; the checker rejects the first larger capture list so code
generation never depends on a Lua API failure. A callable wrapper adds one
source-closure link. If `n == MAXUPVAL`, guarded realization preserves the
value and uses generic dispatch rather than reducing this source limit or
inventing side storage.

Each lambda's native, coercive-Lua, and strict-generic entries are **hoisted
to file scope** and
emitted alongside the top-level functions, named `<modprefix>lambda_<|N|>`.
Because a lambda nested inside another lambda is discovered only while the
outer one's body is generated, the emission loop drains the lambda list
with an index-based `while` that re-reads its length each iteration rather
than iterating a snapshot.

**Transitive capture** (a deep lambda using a variable from a function it
is not directly inside) falls out of the per-frame capture lists: the
variable appears in the capture list of *every* intervening lambda, so
each level reads it from its own `_fn` and pushes it into the next
level's closure. A boxed transitive capture copies the one box pointer all
the way down — every level shares the cell; a by-value transitive capture
copies the immutable value down.

### Bound-method trampolines

A bound method reference `obj:m` is a one-capture closure whose captured
"variable" is the receiver `self`, with **three trampolines** that delegate
to the method's real entries. All three are emitted by the method's
**defining module for every method**. Public methods use exported/recoverable
symbols mirroring the method's own entries plus a `function_type_tag` for the
self-removed type, so a bind site in another module — which may have only the
`.so` — can point at them. Local methods keep those trampoline symbols
file-local and are not serialized into `.so` interfaces. The **native
trampoline** matches the
self-removed function type's ABI, extracts `self` from its closure's
`upvalue[4]`, and tail-calls the method's native entry with that `self`;
the trailing flexible-output descriptor and budget, when present, pass through
unchanged. The **Lua trampoline** inserts `self` as the first stack argument and
delegates to the method's existing Lua entry, reusing its boundary checks.
The **strict trampoline** is generated for the self-removed callable shape: it
preserves the hidden original bound closure, strictly guards the visible
arguments/results, and invokes the native bound trampoline, which extracts
`self`.
At the bind site `obj` is evaluated once into an untraced C temporary. It is
then pushed as the closure's real `self` upvalue while the closure is built like
a one-capture lambda (`_mod`, the self-removed tag, the native trampoline
pointer, `self`, and the strict trampoline trailer). The fresh closure receives
its initial result root immediately. The result is an ordinary source
`Type.Function` value. A downstream
non-exact callable cast uses the same conditional fresh-wrapper/fallback
lowering as any other source closure; it does not require a bound-method
special case.

Interface method calls use the same native method signatures but take their
entry from the wrapper's declaration-order payload. The hidden `_mod` and
`self` values always come from wrapper user values 0 and 1, so an adjustment
entry generated outside the concrete owner's module still invokes the method
with its concrete owner. Interface bound source methods are six-upvalue branded
closures: the first four structural function slots are followed by the
captured wrapper and strict entry. A later adjustment wrapper copies that
capture and appends its immediate-source link under the ordinary layered
layout. The Interface owner exports the native, coercive-Lua, and strict bound
trampolines for cross-provider bind sites. Full
wrapper layout, pair initialization, and all four dispatch paths are in
[Interfaces](interfaces.md#four-dispatch-paths).

### Compiled-module ABI

`TITAN_ABI_VERSION` is the monotonic compatibility marker carried by every
compiled provider. It covers native entry signatures, physical nominal layout
metadata and exact native Option carriers, serialized
type schemas, module-state layout, canonical Array proxies, unions, Interfaces,
generic metadata, source-private provider identity, foreign callback symbols,
and const-qualified descriptors and wrappers. A mismatched provider is rejected
before interface rehydration or native value exchange.

The compiler and standard-library release version is independently
`TITAN_VERSION` `0.6.0`. Its derived `0.6` library version selects
`TITAN_PATH_0_6` and the `lib/titan/0.6` provider namespace; patch releases
share that namespace. The reset provides no migration, compatibility alias, or
cleanup path for earlier Titan installations.

Closure adjustment wrappers reuse the fixed current `CClosure` header and native
call shapes. Their target adapters and strict relays are private consumer
artifacts, with no serialized field, provider symbol, or module-state slot. Any
implementation that needs another fixed slot or signature requires a coordinated
ABI advance.

## The module protocol

Each Lua state owns one canonical `Udata` for each initialized logical module,
registered under `"Titan module <modname>"`. Generated functions receive that
userdata as `_mod`; Lua wrappers recover it from closure upvalue 0. A module
has two storage regions:

* traced uservalues hold variables, imported module userdata, canonical
  closures, metatables, Array writer closures, and nominal namespaces;
* its native payload begins with `TitanModuleData` and holds its immutable
  symbol-resolver callback, resolved dependency pointers and slot numbers,
  canonical function-type tag pointers, and Interface implementation arrays.

State-dependent native bindings never live in mutable file-global C variables.
An immutable symbol resolver can belong to a shared object, a linked archive,
or an executable; it identifies the code that created this module state without
recovering a filename or loader handle.

Public raw [foreign imports](foreign-functions.md#source-collaboration-and-binary-isolation)
have no state argument. Their exact C addresses resolve through the same checked
providers and publish atomically into stable consumer-image slots. A later
state must select the same address; it cannot overwrite a raw binding.

Generated Titan declarations and definitions have protected visibility on ELF,
so a resolver's native addresses bind to its own image despite duplicate
logical-module exports elsewhere. The pragma begins after foreign headers and
ends with the generated module; foreign C linkage is unaffected. Darwin's
ordinary two-level namespace already preserves these image-local bindings.

### `<prefix>_init` — one canonical module per Lua state

The initializer first checks the logical registry key. If a module exists, it
returns that userdata immediately. It does not load dependencies or initialize
another image's function tags, Interface arrays, or native bindings.

When the module is absent, initialization allocates its complete native payload
and uservalues and roots the object privately. It installs the native export
header and physical-provider identity and prepares Array caches. Each explicit
import is selected, checked, and initialized before selecting the next; a
changed canonical selection after initialization is checked again. The module
then resolves transitive owners and fills native entry and slot bindings from
the final canonical providers.
Dependency-check failures occur before the new module is published in the
logical registry, so a caught failure cannot make a retry bypass verification.
Nominal metatables, function tags, Interface arrays and witnesses, Array writers,
canonical closures, variable initializers, Lua member access, and the module
initializer are then prepared in their required dependency order. Each
successful initialization path registers both the native Lua loader and a
separate native provider descriptor through `titan_module_preload`. The
registry table `TITAN_MODULE_PRELOADS_KEY` holds only the matching loader and
`TitanModuleSymbols` resolver pointers, with no module state. Independent
Lua states can copy this descriptor with its matching loader without sharing
module userdata, metatables, or resolved bindings.

A fresh Lua state gets a fresh userdata and fresh native caches even when the
same generated code is shared by both states. Consequently one state's selected
provider cannot overwrite another state's dynamic calls or Interface dispatch.
Record, union, and Interface identity remains the per-state metatable, discoverable
through `TITAN_METATABLES_KEY` and cached in traced module uservalues.

`$INITPAIRS` fills the current module payload's exact/adjusted Interface arrays
once imported native pointers are available. It then raw-checks
`concrete_metatable[target_Interface_metatable]`. A nil entry receives the
pair's private C witness closure with the emitting `_mod` as upvalue 0; an
existing witness is preserved. The closure and metatables are traced Lua
objects, while the pair array contains only native function pointers.

### Lua entries and ABI, type, and layout metadata

`luaopen_<mangled-modname>` is what `require` finds. Standard-library short
imports are desugared before module resolution, so Titan `import "os"` compiles
as an import of `titan.os`; its ordinary qualified module name naturally emits
`luaopen_titan_os`, the same entry used by Lua `require "titan.os"`, without
defining `luaopen_os` or replacing Lua's own `os` library. The Lua entry calls
`_init` and pushes
the module `Udata` itself — so **`require` returns a userdata**, not a table,
with **no separate module table at all**. Its members —
exported functions, exported variables, and one static-namespace table
per public record or union (carrying its public nominal functions and union
constructors) — are all served by a metatable on the
`Udata` ([Lua interop internals](lua-interop-internals.md)).
`<prefix>_abi` is a tiny marker function that returns the current
`TITAN_ABI_VERSION`; both the compile-time DSO loader and generated dynamic imports
check it before trusting any other callable symbol. Static providers embed
the same ABI, serialized interface, and separate physical layout string in each
logical object, and archive validation compares those bytes with the callable protocol before
publication. `<prefix>_types` is the separate-compilation interface:

```c
int counter_abi(lua_State* L) {
    lua_pushliteral(L, TITAN_ABI_VERSION);
    return 1;
}

int counter_types(lua_State* L) {
    lua_pushliteral(L, "Module('counter',{ModuleVariable('counter', 'x', Integer()),...},{['Count'] = Integer()})");
    return 1;
}
```

The literal is `types.serialize(ast._type)`: a Lua *expression* that
rebuilds the module's type when evaluated with `types.lua`'s constructors
as its environment. A `Type.Module` serializes runtime `members` separately
from public type-only `type_members`, which contain transparent aliases and
direct Interface declarations. Neither creates a module slot or Lua-visible
member. Keyed type-member, nominal-method, and nominal-static maps are
serialized in locale-independent numeric-byte name order so equivalent
interfaces have reproducible text; ordered Interface methods, module members,
record fields, and union variants retain their established logical source order.
Physical UV/member indices are independent and never enter that semantic schema.
Contextual `CVoid`/`CInteger`/`CFloat` descriptors and recursively portable
`CPointer`, nonvariadic `CFunction`, and `COwned` graphs are serialized
structurally without source scope or header provenance, while named header
`CTypedef`, `CStruct`, and `CUnion` descriptors serialize with their
`c_declaration_origin` provenance so consumers can verify original compatible
declarations. Enum identities, unnamed aggregates without a typedef name, and
flexible-array aggregates never enter this literal.
Callable declaration descriptors also serialize formal
`paramnames`, while structural `Type.Function` values do not. Callable shapes
also carry their optional `flexrettype`; accepting that new constructor shape
from compiled interfaces is gated on the coordinated ABI transition described
above. It returns that
serialized interface as its sole result;
there is no dependency-origin metadata in the module protocol.
`Type.Module.file` is likewise omitted. It defaults to the exact logical path
when the expression is evaluated; only a successful DSO claim overwrites it
with the selected relative shared-provider path. Static archive paths never
enter the serialized type or this transient field.

`<prefix>_layouts` returns one binary graphcodec string emitted with
`lua_pushlstring` and an explicit byte count. `nominallayout.decode` validates
its module identity and closed physical schema independently of `_types`.
Native loading retains those plans in the resolver's `nominal_layouts` map and
passes them as separate coder options; analysis clients keep their existing
ABI/types inventory. No private C declaration graph is exported. See
[Native nominal storage](nominal-storage.md).

When the driver's loader finds a compiled provider for an import, it recovers
the requested ABI/types from either the DSO's callable pair or the selected
archive object's canonical metadata section, rejects partial or invalid
claims, validates the additional layout string for native compilation, and
evaluates the serialized expression to recover the interface —
letting the checker type the importing module against a dependency whose
source is gone. Libuv does not add another result or a special binary
classification. Dependencies selected from a DSO use canonical logical-provider
wiring; dependencies selected from source or a static provider use direct
native wiring. Explicit command-line roots are the source-first exception.
The tests' in-memory `tableloader` exercises the same serialization
round-trip. See [driver and toolchain](driver.md) and [Static compiled
modules](static-compiled-modules.md).

Folder and provider representation change none of this logical protocol.
Mangled symbols, nominal names, registry keys, `luaopen_*`, and the serialized
module identity remain derived solely from logical `modname`; there is no
contributor ABI. Moving local declarations or private state among contributors
can change private initialization layout without changing the serialized
interface. Physical-provider selection, Array representation, union and
Interface schemas, public nominal-static slots, callable branding, and the
fixed provider-identity slot are instead coordinated parts of the current
compiled-module ABI.

## Static vs dynamic dependency wiring

`coder.generate` decides per import using finalized `static_deps[modname]`
provenance (`import_module` and `init_data_from_other_modules`).

**Direct/static** dependencies are source objects or archive members carried
inside the same binary. Their native functions use `extern` declarations and
direct calls, and their public slots retain compile-time constants. Their
initializer is called directly, and its returned module must carry the exact
linked producer's physical identity. A same-name module created by another
image cannot safely supply the private state expected by direct native code.

**Dynamic** dependencies first use `titan_module_provider` to look up the
logical module in the Lua registry. An initialized module supplies its native
export callback, even if its code is embedded in the executable or was opened
locally through `package.loadlib`. If the module is absent, a copied native
provider descriptor supplies its resolver; the selected DSO filename is
consulted only when neither is available. Descriptor lookup does not call a Lua
preload loader or initialize the dependency. ABI and consumer-specific
compatibility checks run before calling the selected initializer, whether its
code came from a copied resolver or a newly opened DSO.

`titan_module_symbol` resolves the required metadata callbacks, native entries,
bound-method trampolines, and public slot numbers through that selected provider.
The importer saves its bindings in its own module native payload. Direct calls
remain typed native calls with the dependency's module userdata and `NULL`
closure argument; they do not fetch a first-class closure or invoke a Lua
namespace lookup. First-class functions instead read the canonical closure at
the provider's resolved slot.

For a **transitive dynamic owner**, initialize the explicit exposing imports
first, then use `titan_module_provider` with the owner's logical name and a null
filename. That owner must already be initialized; an uninitialized copied
descriptor does not satisfy this canonical-only lookup. Its own ABI and selective
compatibility checks precede native lookup through its export callback; global
symbol order does not choose the owner. The corresponding module userdata and
nominal metatables are recovered from the same Lua state's registry. See
[Type aliases](type-aliases.md) and [Selective binary dependency
verification](binary-compatibility.md).

The underlying `loadlib` still maps newly needed DSOs with
`RTLD_LAZY | RTLD_GLOBAL`. This supports ordinary native-library relocations:
for example, an extension can initialize its imported standard provider before
its lazy `uv_*` calls bind. This C-linker behavior is distinct from Titan's
logical module binding. Eager data/function-address relocations and native
constructors cannot rely on initializer ordering. Compiler interface inspection
remains a separate `RTLD_LAZY | RTLD_LOCAL` operation.

## User-value allocation

`allocate_upvalues` assigns `_mod` user-value slots before any code is
generated. `nextupvalue` hands out slots 0-based with no reserved slot
(the now-removed module table no longer takes slot 0), so `NUPVALS`
equals the number of slots. `_public_prefix_layout` derives the ABI-visible
prefix entirely from the serialized interface:

1. exported module variables in module-member order;
2. exported ordinary-function canonical closures in module-member order; then
3. exported static closures for each public record or union, with owners in
   module-member order and statics in bytewise name order.

The producer stamps the corresponding AST declarations. A same-binary importer
walks the same layout; a separate dynamic importer resolves the producer's
exported closure slot symbol. Both read the exact canonical first-class closure
for an imported constructor or nominal function. The unconditional mutable and const Array
metatable caches occupy the first two private slots. One fixed lightuserdata
slot containing the source producer's immutable physical-provider token
follows them, before the
fixed AST-order allocation for local variables/imports, referenced local
ordinary-function closures, every static not already in the public prefix, and
each nominal owner's private static-namespace table. Every direct importer
compares that token with the hidden identity function of its exact linked
producer before using its state; explicit source imports additionally depend
on the fixed source-private slots. Remaining private slots are
allocated as
their inventories or first uses are encountered during code generation:
module-local Array writers; record/union, Interface, and owned-C metatables;
concrete-owner module caches needed by wrappers; transitive module
`Udata` caches; and up to three error-recovery `TString` anchors
(`TITAN_BACKTRACE_KEY`, `TITAN_TRACE_PINNED`, and `""`) requested by
generated `catch`/`defer`/re-raise code may therefore interleave. No ordering
among those categories is serialized.

Any requested error-recovery `TString` slots are initialized first in
`$INITNAME`, immediately after `titan_pushmodule(L, _mod)` and before
metatables, dependency loading, or generated initializers/bodies can enter a
protected boundary. Code generation also freezes the distinct constructed
Array element types and initializes each corresponding writer after nominal
metatables, imports, and function-type tag publication but before `$INITVARS`,
so an initializer can construct an Array without observing an empty slot.
Publishing tags first is also required because a variable initializer may
construct a lambda or bound-method closure and must copy a live exact tag into
it. Other first-use private objects are filled by `init_data_from_other_modules`
or the module initializer. Thus all private slots, beginning with the Array
cache and fixed provider-identity token, come *after* the importer-visible
public prefix. Their fixed header is part of the current ABI, while later
inventory/first-use slots remain coder-private and do not perturb the public
importer slot math.

An importing module never sees this module's AST. The `Type.Module` interface
reconstructs the public prefix at compilation, but a separately loaded provider
may later reorder compatible declarations. Cross-module variable access still
uses `uvalue(&_mod->uv[MOD].uv)->uv[VAR].uv`: `MOD` is the constant consumer-owned
import slot, while `VAR` comes from the provider's exported variable-slot symbol
for a dynamic dependency and remains constant for a same-binary dependency.
Canonical callable slots use the same rule; direct native calls bypass them.
The module metatable's name-to-slot map serves Lua using the producer's own
current indices. See [Selective binary dependency
verification](binary-compatibility.md#provider-owned-slots-and-direct-calls).
A nominal owner's type identity is its per-Lua-state metatable
pointer, so record and union metatables must live in module user values and are
recovered through the Lua registry for imported owners. Function-type tags use
a separate registry-published identity whose pointer is cached in the module
native payload before any variable initializer can construct a closure. The type-independent closure brand is a
compile-time ABI sentinel and needs no initialization or registry state.
Canonical top-level/static closures are populated before variable initializers
and before module exposure.

## Per-function code-generation contexts

Code generation for one function body runs inside a context created by
`newcontext(tlcontext)`. Its bookkeeping fields:

* `tmp` — autoincrement counter for temporary names (`_tmp_1`, …).
* `depth` / `nslots` — current Lua-stack-slot depth and its high-water
  mark. `newslot(ctx, name)` hands out the next slot as
  `TValue *<name> = s2v(_base + <depth>);`, bumping both; `pushd`/`popd`
  save and restore `depth` around blocks and loop bodies so sibling
  blocks reuse slots. The final `nslots` sizes the function preamble. The
  preamble **always** declares `_base = L->top.p`, and only when
  `nslots > 0` does it additionally run `luaC_checkGC`, reserve `nslots`
  stack slots above `_base`, and nil them. Every `return` unconditionally
  restores `L->top.p = _base` first — because an early return is coded
  before the function's final `nslots` is known (a later statement can
  still raise it), the reset is uniform across all return paths (a no-op
  when no slots were reserved) rather than chosen per-return from the
  current slot count.
* `allocations` — incremented by every `newslot`; loop generators compare
  it across the loop body and emit a per-iteration `luaC_checkGC(L)` only
  when the body actually allocates.
* `names` — autoincrement suffixes used by `localname` to give each
  declared local a distinct C name (`_local_x_1`, `_local_x_2`, …), so
  Titan redeclaration and shadowing translate to valid C.
* Shared accumulators pointing back into the toplevel context (`tags`,
  `metatables`, `functions`, `variables`, `modules`): codegen records
  here each external record, function or variable it touches;
  `init_data_from_other_modules` later turns the sets into declarations
  and init-time wiring.

The central value-handling idiom is the **dual representation** produced
by `newtmp(ctx, typ, isgc)`: a C variable `_tmp_N` of the value's native
unboxed type, paired — when the type is garbage-collectable — with a
stack slot `_tmp_N_slot`. Code computes into the C variable and
immediately stores into the slot, so the value is visible to the
collector before the next possible allocation. When a slot is required,
where `luaC_checkGC` goes, and which write barrier each store needs are
the subject of [values and the GC](values-and-gc.md).

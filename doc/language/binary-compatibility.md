# Replacing shared-library dependencies

A compiled Titan consumer can load a replacement shared provider without being
rebuilt when the replacement preserves the declarations that consumer depends
on. Adding an unused function, removing an unused variable, or changing private
record storage does not by itself invalidate the consumer.

These checks apply to dependencies loaded from **separate shared objects**.
Source modules and static archives linked into the same library or executable
are fixed parts of that binary. Replacing an archive or source file on disk
does not replace its already-linked code. See [Modules](modules.md) and
[Static compiled modules](static-compiled-modules.md) for dependency selection.

Within one Lua state, the first initialized provider of a logical module is
canonical. A later dynamic import uses that module and checks its own requirements
against it before using its native entries. It does not open a second provider
just because a different file was selected when the consumer was compiled.
This also applies when the canonical module was linked into the executable,
loaded from an archive, or initialized through Lua's `package.loadlib`.
For example, a dynamically loaded plugin importing a module already supplied
by its host executable uses the host's initialized module.

## What a consumer requires

Titan first checks the provider's compiled-code ABI. If that matches, it checks
the consumer's required interface before using the provider's native entries.
An incompatible replacement fails while loading the consumer, even if the
affected consumer function would not have been called in that execution.

| Referenced declaration | What must remain the same |
| --- | --- |
| Function | Erased parameter and result types, parameter names, variadic input, and flexible-result shape. |
| Module variable | Erased type and mutable/const status. Declaration order may change. |
| Record | Nominal identity and the complete ordered list of public field names, erased types, and constness. |
| Union | Nominal identity and the complete ordered list of public variant names and named payload signatures. |
| Interface | Nominal identity and every ordered field and method signature, including method parameter names. |
| Concrete record/union method or static function | Its signature and parameter names, when the consumer uses that member. |

The record and union rules apply to the whole public data shape, even when a
consumer reads only one field or matches one variant. Concrete methods and
static functions are checked individually; adding or changing an unused method
does not invalidate a consumer. Interfaces instead require their complete
declared shape because compiled wrappers depend on it.

"Uses" includes reads, writes, direct calls, first-class function references,
bound-method references, and nominal types in annotations or inferred values.
It also includes dependencies introduced by implicit conversions: converting
a record to an Interface relies on the concrete methods used to implement that
Interface even without a written concrete method call.

The comparison uses Titan's ordinary generic erasure. It compares a generic
declaration's runtime signature, rather than specializing compatibility to
one call's type arguments. Generic source parameter names such as `T` may
change without changing that erased contract; callable parameter names such
as `input` remain part of the contract.

Nominal aliases preserve both the exposing name and the original owner. If a
consumer names `api.Item`, removing that alias or redirecting it to another
record is incompatible even when the two records have identical fields.
Types and methods reached through another module's signatures retain their
canonical owner requirements as well.

## Reordering module declarations

Used functions and variables can move relative to other module declarations.
For example, this consumer continues to work when the provider adds variables
or changes the position of `count` and `advance`:

```titan
local counter = import "counter"

function tick(): integer
    counter.count = counter.count + 1
    local advance = counter.advance
    return advance(counter.count)
end
```

The replacement must preserve the used variable and function contracts. A
direct `counter.advance(...)` call still invokes the native function directly.
A `counter.advance` value still denotes the provider's canonical function
value; repeated exact references keep their identity. The same applies to
first-class public record/union constructors and static functions.

## Private record fields and construction

A replacement can add, remove, reorder, or change private fields while
preserving a referenced record's public shape. Consumers that receive the
record and access its public fields can continue to use it.

Construction has an additional dependency. Constructing an imported record
with a raw literal requires that its fields remain all public and that `new`
remain the generated default:

```titan
local model = import "model"

function make(): model.Point
    return { x = 1.0, y = 2.0 }
end
```

Adding the first private field or overriding `new` therefore rejects this
literal consumer at load time. An override with the same signature can remain
compatible with an ordinary `model.Point(...)` or `model.Point.new(...)` caller.
A generated constructor call used in a constant module variable initializer
also requires the default constructor, including when nested inside another
constant expression. An override would invalidate the initializer's
constant-expression guarantee, so that consumer rejects it at load time.
A call that fuses fresh native storage into the record's own allocation also
relies on the generated default and rejects an override; that construction
preserves the buffer's lifetime as part of its record.
A consumer that only receives a `Point` from a provider
function and reads `x` or `y` can remain compatible. See
[Native storage](nominal-storage.md) for storage and ownership rules.

Providers built before the literal-construction capability was introduced need
rebuilding for newly compiled literal, constant-initializer, or fused-storage
consumers. Older consumer binaries only recorded a `new` dependency and do not
enforce the override restriction.

## Private union variants and control flow

Private variants may change while the ordered public variants remain the same.
Public tags stay stable when private variants are added or reordered.
An unmatched `case` with no `else` continues after the case; a replacement does
not introduce an implicit exception or a coverage requirement.

There is one additional requirement when the compiler used complete variant
coverage to prove that control cannot fall through:

```titan
local events = import "events"

function describe(event: events.Event): string
    case event
    when started() then return "started"
    when stopped() then return "stopped"
    end
end
```

If `started` and `stopped` were the complete original inventory, adding a
private variant invalidates that proof. Loading this unchanged consumer fails.
The same applies to a redundant, falling-through `else` whose unreachability
was established by complete coverage. An independently terminating `else`
does not depend on the inventory and permits private additions.

This preserves [ordinary non-exhaustive case
behavior](unions.md#non-exhaustiveness-and-control-flow-analysis). Consumers
whose cases do not rely on complete coverage accept otherwise compatible
private-variant changes.

## Build and deployment boundaries

Compatibility is a per-consumer check of compiled assumptions, not a promise
that a replacement preserves application behavior. A function can return a
different value while retaining its signature. Changes to required signatures,
public nominal data shapes, or ABI require rebuilding affected consumers.

The compiler continues to read complete type and physical-layout metadata when
building a consumer. The load-time compatibility protocol is separate from
those formats. A provider missing that protocol is rejected when used as a
separate shared dependency. Build providers and consumers with a matching
Titan compiler/runtime; the current compiler version remains `0.6.0` and the
compiled-code ABI remains `2`.

For native bootstrap code, newly generated logical modules also export
`const char *<mangled>_abi_value(void)`. This C function returns the same ABI
value without a Lua state, allocation, or module initialization. The result is
an immutable provider-owned string; do not free it, and keep the provider
image loaded while using it. Each logical module has its own query, including
modules sharing one physical provider.

This query is a native bootstrap primitive. The existing Lua-callable `<mangled>_abi(lua_State *)` entry and Unix loading
behavior remain unchanged; older ABI-2 providers do not need the new query for
those existing paths. Do not call `_abi_value` through `package.loadlib` or
`titan._loadlib`: those helpers return Lua C functions with a different calling
contract.

Checks occur during loading. Replacing a file does not hot-reload a provider
already initialized in a running Lua state. Each Lua state owns its module
instances and native bindings independently. Dependencies linked directly into
a binary must use that binary's own provider; finding a different initialized
provider for such a dependency is an error. Test a replacement deployment using
a fresh process and the unchanged consumer binary, and test plugin integration
with the host's modules already initialized.

## Experimental Windows loading and launchers

The Windows runtime checks each logical module's `_abi_value` before calling
its Lua metadata entries or initializer. Windows providers must supply that
query, even though it remains optional for existing Unix ABI-2 providers.
Executables, the controlled Lua DLL, and native dependency DLLs share `bin`;
Titan provider DLLs belong in `lib/titan/0.6`. For explicit Lua and Titan module
loads, dependency-search flags add only the executable directory and System32;
they do not add the current directory, provider directory, or global `PATH`.
Windows still applies its already-loaded-module, KnownDLL, and API-set rules.
These flags do not constrain initial EXE imports, which Windows resolves before
runtime initialization. Titan's Lua interpreter, compiler frontend, and
application launchers must retain their adjacent controlled Lua DLL.
`TITAN_PATH_0_6` takes
precedence over `TITAN_PATH`; an explicitly empty value disables the fallback
Titan path.

For a standalone logical module `app.main`, the Windows compiler emits
`bin/app.main.exe` and its application provider at
`lib/titan/0.6/app/main.dll`. A folder module named `app` instead uses
`bin/app.exe`; contributor filenames do not determine its launcher name.
`--launcher-name NAME` overrides the launcher basename and appends `.exe`
unless that suffix is already present. It accepts one valid Windows filename,
not a path, and is valid only for Windows standalone or `--test` builds.
A test launcher's default name follows the first requested logical root.

The launcher embeds the selected logical module and relative provider path.
Renaming the EXE within `bin` therefore preserves loading; an override does not
rename or change the provider. The existing argument Array, protected error
handling, process exit status, and optional `--no-uv-bootstrap` behavior apply.
The launcher runs with the caller's privileges and declares UTF-8 and long-path
support in its application manifest. Unix output names and entrypoints are
unchanged.

Titan retains successfully mapped Windows providers until process exit,
including after a Lua state closes, so native callbacks and finalizers retain
valid code. Canonical logical-module identity still belongs to each Lua state.
Generated Lua shims first locate their provider through `package.cpath`, then
reuse an initialized canonical module before opening or checking another image.
A missing provider pathname still fails that initial shim search.

A Windows invocation without `main` emits one DLL named from the requested
roots' longest common dotted prefix and one Lua shim per carried logical module.
For example, `smoke.leaf` produces `smoke/leaf.dll` and `smoke/leaf.lua`.
Windows does not emit a paired Titan archive and rejects `--static` or selected
Titan archive providers. Native object payloads and native import libraries
remain separate linker inputs.

Publication validates metadata in a fresh process before replacing outputs.
If another process has mapped an existing provider, replacement fails and the
previous DLL and companion shims are restored. Caught-error recovery preserves
file bytes; it is not a crash-atomic or concurrent-publisher transaction.
Removing logical modules from an existing Windows provider does not retire old
shims automatically; use a fresh output directory for that change.

These are experimental compiler and runtime foundations, not a complete
Windows distribution. Windows error traces currently preserve Lua frames and
raw native addresses; native Titan source-line attribution remains unavailable.
Unix loader behavior and source attribution are unchanged.

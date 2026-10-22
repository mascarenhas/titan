# Record constructors

The [language contract](../language/records.md#calling-a-record) distinguishes
calls to a record's `new` from raw context-typed record literals. Calling a
record namespace is syntax sugar: it adds no callable type and does not make
namespaces first-class Titan values.

## Declaration staging and call lowering

`defs.recorddecl` (`titan-compiler/parser.lua`) emits each record followed by
a synthesized `TopLevelStatic` named `new`, marked `_record_constructor`, whose
body is an `ExpInitList` over the field parameters. Before nominal signatures
are staged, `collect_nominal_constructors` (`checker/declarations.lua`) finds
written record statics named `new`. For each such owner it sets
`_custom_constructor` on the `TopLevelRecord` node and removes the synthesized
declaration from the AST with `table.remove`. The written static then goes
through ordinary declaration checking. All other declarations keep their order
and locations. A second written `new` is an ordinary duplicate error.

The override follows ordinary static-function rules, including visibility,
generic parameters, variadic input, and zero, multiple, or flexible results.
Its result need not be the owning record. The removed constructor has no body,
tag, or closure slot, and the override cannot reach it.

The call checker (`checker/expressions.lua`) rewrites a call whose callee
resolves to a `Type.Record` namespace into `VarDot(namespace, "new")` and
checks the new callee as an ordinary member selection. The ordinary member and
call paths then own access checks, inference, argument evaluation and
adjustment, result demand, and named-argument normalization. Only namespaces
are rewritten: a local value that shadows a record name keeps its ordinary call
behavior. Imported records, [alias namespaces](type-aliases.md#frontend-and-resolution),
and `M.Record` reach the same namespace path.

The parser attaches a final written type-argument list to the call. The
rewrite moves that list to the namespace (`_nominal_typeargs`) before
selecting `new`, so `Box<|integer|>(x)` means `Box<|integer|>.new(x)`.
Callable-local generic arguments of an override still follow `.new`, under the
ordinary all-explicit-or-all-inferred rule.

## Raw construction and generated-only operations

`Type.Record.custom_constructor` is a boolean, independent of `new`'s
signature and visibility, so even a same-signature override changes
construction authority. `generic_resolve_named_record_constructor_context`
(`checker/expression_lists.lua`) rejects a raw `ExpInitList` for a record with
this flag outside its owner module: "cannot construct record type '%s' outside
module '%s' because it has a custom constructor". The test compares module
names only, so a source-collaboration import does not gain the defining
module's raw-allocation privilege. The private-field rule applies
independently.

Three checker paths treat only the generated `new` as a constructor:

| Function (file) | Behavior limited to the default constructor |
| --- | --- |
| `_direct_nominal_constructor` (`checker/calls.lua`) | native field and tail allocation plans |
| `record_constructor_parameter` (`checker/common.lua`) | mapping synthesized parameters to field declarations |
| `isconstructor` (`checker/declarations.lua`) | accepting the call as a constant module-variable initializer |

A custom constructor in its own module can allocate with a context-typed
literal, which uses the ordinary layout, rooting, and write-barrier code
generation.

## Semantic metadata and separate providers

`custom_constructor` is the optional eighth `types.Record` argument, after the
generic scope and parameter list, and defaults to false. `types.serialize`
keeps the default-record form and appends `true` only for an override,
inserting the empty generic positions (`nil,{}`) when needed. Equality,
substitution, erasure, source-interface graphs, and persisted declaration
schemas preserve the flag. Physical nominal layout and native calling
conventions do not depend on it.

`validate_record_interface` (`driver.lua`) requires the flag to be a boolean
and always validates the ordinary callable graph. The generated-`new` shape
checks apply only when the flag is false: field-named parameters, one
owning-record result, no tails or callable-local binders, and a present `new`
on an all-public record. A private custom `new` is simply absent from the
public interface.

The flag also removes the provider's `literal` capability (`binarycompat.lua`
`nominal`). Raw literals, generated constructor calls that `isconst` accepts
in a module-variable initializer (marked `_binary_constant_constructor`), and
calls whose fresh native arguments are fused into the record allocation all
require that capability. A replacement provider that overrides `new`
therefore rejects those consumers, while ordinary calls depend only on `new`'s
signature and run the provider's implementation. Local, source-linked, and
archive-linked generated constructors may still be inlined; the final link's
static-dependency classification chooses call or inline. The complete rule is
in [Construction and closed-union
proofs](binary-compatibility.md#construction-and-closed-union-proofs).

## Lua namespace calls

`coder.generate` (`coder/generate.lua`) gives a record's static-namespace
table a metatable with `__call` only when `new` is public. The generated entry
(`coder._nominal_metamethod_name(owner, "call")`) receives
`namespace, args...`, replaces stack slot 1 with the namespace's `new` member,
and calls it with `lua_callk(..., LUA_MULTRET, 0, <name>_finish)`. Both the
entry and its `_finish` continuation return `lua_gettop(L)`, so zero results,
multiple results, interior nils, and flexible tails pass through, and Lua can
yield if a Lua program replaced the public `new` member with a yielding
callable. The Lua stack roots the namespace, arguments, constructor, and
results throughout; the bridge holds no raw stack pointers across the call.
Errors propagate normally.

This metatable belongs to the namespace table, not to the nominal instance
metatable. A private `new` creates neither a public member nor a namespace
`__call`. Direct Titan calls keep their statically checked native or canonical
callable paths.

## Standard-library use

Standard-library Titan record calls use the shorthand, while C allocation
pseudo-calls keep `foreign T.new(...)`. `titan/string/format.titan` declares
`local function StringWriter.new()`, which builds its raw state with a literal
and is called as `StringWriter()`.

The JSON decoder (`Decoder:decode_record`, `titan/json/decoder.titan`) invokes
the reflected public `new` with values mapped by its parameter names. It
accepts a constructor only without variadic input or flexible results and with
exactly one result of the requested record type. Any other signature fails with
`constructor_unavailable` before invocation; reflection itself still exposes
every public callable.

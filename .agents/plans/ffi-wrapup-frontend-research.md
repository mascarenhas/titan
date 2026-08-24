# FFI wrap-up frontend research: `foreign function` and `foreign <function type>`

Status: research only. This file describes the smallest architecture-consistent design; this research did not edit tracked compiler sources or the draft plan.

## Executive recommendation

Implement the feature as two new **AST** forms that lower into the existing C type system:

* `Ast.TypeForeignFunction` lowers to `Type.CPointer(Type.CFunction(...))`.
* `Ast.TopLevelForeignFunc` carries a direct `Type.CFunction(...)` declaration.

Do **not** add another semantic callable type. `Type.CFunction`, the C declarator renderer, C call checking, C operator resolution, pointer/function-pointer casts, origin-header tracking, and the direct-source visibility mechanism already provide the semantic substrate.

A foreign function is not a Titan closure with a different wrapper. It is a raw C definition with an injective source-private native name, no module/userdata slot, no Lua entry, no strict entry, no `_mod`, no `_fn`, no implicit `L`, no automatic stack roots, and no Lua error path. Its body therefore needs a deliberately small checker and emitter. Reusing `checkfuncbody`/`codefuncdec`, or merely post-validating their output, is not sound: those paths insert Titan coercions, Lua truthiness, numeric-for error handling, stack restoration, null/bounds errors, GC roots, and closure machinery.

Generate source-only headers in a driver prepass after checking and output preflight but before **any** source object is compiled. A consumer can sort before its producer, so generating a header as a side effect of compiling its owning module is too late. Headers are compiler-only build artifacts and are never serialized or installed as binary-module interfaces.

For the Lua function-like macros, use typed `static inline lmacro_*` wrappers in `titan/ffi.h` for this wrap-up. Generic function-like macro exposure lacks a type contract and is materially larger than the foreign-function feature.

## Invariants to preserve

1. **Trusted FFI boundary.** Raw C values and pointers are trusted. A foreign body must not quietly reintroduce Lua null/bounds/type errors. Direct pointer calls, field access, and indexing use C behavior; the compiler should not manufacture an `L` just to validate them.
2. **Direct source authorization only.** A source foreign function is visible only through its owning module or an alias for a direct, loader-authorized source import. Binary `.so`/`.a` interfaces, Lua maps, physical co-residence, `static_deps`, registry state, and another module's source capability do not reveal it.
3. **FFI context is separate from member capability.** Required ordered C headers/type origins may travel through the existing source-only FFI provenance, but a `foreign import` alias never does. A generated header is a C declaration dependency, not a Titan visibility grant.
4. **No serialized compiler view.** Foreign functions and generated-header paths are absent from `Type.Module.members`, `_types`, static metadata, and archive metadata. They may appear only in `source_members` and AST/driver annotations that the metadata validator already treats as compiler-only.
5. **No function-value/module-state layout change.** A foreign function is not a `Type.Function`, has no canonical CClosure, and contributes no public or source-private module-userdata slot. `types.source_module_prefix_layout` already selects only `Type.Function` module members and should continue to do so.
6. **C evaluation with Titan source sequencing.** Raw operators use the checker-selected C semantics, but expressions are still evaluated once and in Titan's left-to-right order. Materialize operands and arguments before composing C expressions because C argument/operand order is otherwise unspecified.

## Syntax and AST

### Top-level declaration

Add:

```titan
foreign function callback(req: *uv.uv_req_t): ffi.int
    ...
end
```

with the dedicated node:

```lua
Ast.TopLevelForeignFunc(loc, name, params, rettypes, flexrettype, block)
```

Do not give it an `islocal` flag. It is source-only by construction. There is no `foreign local`, `local foreign function`, foreign method, or foreign static declaration.

Parser changes:

* Put `toplevelforeignfunc` before the existing foreign-import alternative in the top-level choice.
* Keep `local name = foreign import "..."` unchanged.
* Commit `foreign function` to function-specific name/parameter/end diagnostics using the existing labels.
* Add a focused syntax error for both `foreign local function` and `local foreign function` rather than letting either fall into an unrelated local-variable error.

`foreign` is already a keyword; `lexer.lua` needs no token change.

### Function-pointer type constructor

Add:

```titan
local type Callback = foreign (*c.Request, c.int) -> (c.int)
local type VoidCallback = foreign () -> ()
```

with:

```lua
Ast.TypeForeignFunction(loc, argtypes, rettypes, varargtype, flexrettype)
```

It must lower to a **pointer** to a C function:

```lua
types.CPointer(types.CFunction(params, ret, false, false), {})
```

The pointer layer is required by the motivating example: `pvalue(...)` is a `void *`, and the written alias is the cast target and callable function pointer. A declaration node, by contrast, has the direct `CFunction` designator type just like an imported C function.

Use the same default ABI sentinel as imported C declarations (`false` today). Do not invent the string `"cdecl"`: `types.c_function_types_equal` compares `abi` exactly, so that would make a source-written callback incompatible with every ordinary imported C prototype.

Reuse `arglist`/`rettype` parsing so malformed multiple/flexible/variadic shapes receive normal syntax first and precise checker diagnostics second. The constructor can be admitted wherever a type is legal, including below `*`; it is already pointer-valued, so `*foreign (...) -> ...` deliberately means pointer-to-function-pointer.

## Signature checking

Factor one helper used by both new AST forms. It should:

1. Resolve all annotations after foreign imports and aliases have been collected.
2. Apply C parameter adjustment (`cdeclarator.adjust_parameter_type`) so an imported array/function typedef in parameter position becomes the corresponding pointer.
3. Require a raw, declarator-valid C type for each parameter.
4. Map an empty result list to `Type.CVoid()`.
5. Permit at most one result; reject flexible returns and input variadics.
6. Reject `void` as a written parameter or local. Prefer `()` over a written typedef-to-void result so source arity stays unambiguous.
7. Reject a returned array or direct function type; require a pointer instead.
8. Require complete by-value structs/unions/arrays using the existing incomplete-object diagnostic, while allowing pointers to incomplete objects.
9. Run the existing enum-carrier certification over the complete signature.
10. Retain the source parameter names as declaration-only metadata for named Titan call syntax; diagnose duplicates normally.

`types.is_direct_c` is a useful first gate but is not sufficient on its own: it includes `CVoid`, `CFunction`, `CArray`, and `COwned`. In this raw boundary:

* `TValue`, `Udata *`, `CClosure *`, C structs/unions, C scalars, object pointers, and function pointers are ordinary raw C types.
* `COwned` should be rejected in signatures/locals for the initial feature. Although it renders as `Udata *`, it is a Titan GC-ownership view with special unboxing/allocation behavior, not a plain C declaration capability. Callers can write the exact raw `Udata *` when that ABI is intended.
* `.new`/`.new_array` pseudo-calls must be rejected because they allocate Lua-owned userdata and require `L`. `sizeof`/`_Alignof` pseudo-values are runtime-free and can remain available.

The top-level signature pass should include foreign functions alongside ordinary callable signatures, after imports and aliases and before bodies/module variables. That gives forward and mutual references the existing placement independence.

## Source-only semantic view

In `makemoduletype`, create a `Type.ModuleMember(modname, name, cfunction, paramnames)` only in `source_members`, with a compiler-only marker such as:

```lua
member._foreign_source = true
```

The owning AST declaration can carry `_foreign_module = modname`. A single helper should recognize three direct C designators:

* a `TopLevelForeignFunc` in the current source module;
* a marked `ModuleMember` reached through a direct source import;
* an ordinary `CModule` function declaration.

Return a small compiler-only reference `{ module, name, source = true }` for source functions, or the public C spelling for a C import. Use it in all of:

* direct-call checking/lowering;
* contextual decay to an exactly compatible `CPointer(CFunction)`;
* named-argument metadata;
* assignment-to-declaration rejection;
* direct-call/generic-call classification.

Derive the native symbol in the coder, not in serialized types. Reuse the injective ordinary-local native entry name:

```lua
func_name(modname, name, true)
-- titan_source_<hex module>_<hex member>_titan
```

This satisfies the draft's “same name as a Titan native entry point,” avoids public mangling collisions, and aligns with the direct-source symbol model.

Binary imports naturally remain public-only because serialized `Type.Module` has no `source_members` or marker. Do not add a metadata constructor or attempt discovery from a static provider's symbol table.

## Dedicated foreign-body checker

The plan explicitly calls for a specialized checker; that is the smallest reliable implementation. A useful implementation pattern is a `st.foreign_body` context plus dedicated statement visitor. Existing expression handlers may be reused where they already compute C operator/call plans, but every recursively reached expression must see the foreign context. Avoid a module-global depth counter: nested checker invocations and internal exceptions can leak it.

### Visible declarations

Permit only:

* current foreign parameters and locals;
* current-module foreign declarations;
* foreign-import aliases and their C members/types/macros;
* direct source-import aliases, and then only marked foreign members;
* C type namespaces and runtime-free `sizeof`/`_Alignof` pseudo-values.

Reject ordinary top-level/module variables, Titan functions, records/unions/interfaces, methods/statics, `L`, `M`, and ordinary members of imported Titan modules. Keep the alias qualification requirement. A direct source module A importing B does not let A's consumer see B's source foreign functions unless the consumer imports B directly.

### Statement allowlist

Allow:

* block / `do`;
* local declarations;
* assignment;
* C call statements;
* `if`/`elseif`/`else`;
* `while`;
* `repeat`;
* numeric `for`;
* `return`;
* `break` inside an allowed loop (it is runtime-free and is the natural interpretation even though the draft's parenthetical list omits it).

Reject with feature-specific diagnostics:

* generic `for ... in`;
* `case`;
* `raise`;
* `catch`/`finally` (`StatTry`);
* parser-lowered `defer` (`StatTry._defer_tail`);
* nested/anonymous Titan functions;
* record/array/map/union constructors;
* bound methods;
* `...` expressions;
* string concatenation.

Do not merely run the ordinary statement checker and post-walk for forbidden tags. Ordinary checking already inserts the wrong Boolean/numeric/coercion plans and rejects C numeric-for controls before the post-walk runs.

### Foreign literals

The literal handlers need foreign-context types:

| Titan token | Foreign-body type/emission |
|---|---|
| `true`/`false` | target profile `_Bool`, emitted `1`/`0` |
| small integer | target profile C `int` by default, or the contextually required compatible C scalar |
| float | C `double` by default, or contextual compatible C float |
| string | `const char *`, emitted as a C string literal with static storage |
| `nil` | keep a contextual null-literal marker/`Type.Nil`; emit `NULL` and allow only a compatible C pointer/function-pointer sink |

An unannotated `local p = nil` has no pointee type and should be rejected; `local p: *c.T = nil` is well defined. If a Titan integer literal is outside target `int`, either choose the normal C99 decimal candidate using the target profile or require a contextual target and diagnose it. Do not silently type it as Titan `integer`.

### Expressions and conversions

Reuse the checker-selected `csemantics` traits for C arithmetic, comparison, bitwise, shift, dereference/field/index operations, direct C calls, and function-pointer calls. Enforce that every stored local/result is raw C after parameter adjustment. Cast endpoints must be raw C, apart from the literal exceptions above; `value`, Titan numeric/string values, Options, collections, nominals, and Titan functions never cross this boundary.

Some existing coercion plans require special raw lowering and cannot become a generic C cast:

* `mutable_c_address` / `c_address` -> `&lvalue` (or a materialized addressable temporary);
* function-pointer/object-`void *` conversions -> `titan_cast_func` where the existing coder requires it;
* pointer qualification/object-pointer conversions -> ordinary C cast/identity as authorized by the plan;
* nil -> `NULL`;
* C numeric casts -> C semantics, without Titan range exceptions;
* active object-like field macro projections -> preserve the checker's public-spelling/path annotation rather than falling back to a physical field.

A foreign function can explicitly call a Lua API with an explicit `lua_State *`, and that C API may longjmp. That is trusted FFI behavior; the compiler must not add a setjmp frame, spills, or recovery.

### Conditions and numeric `for`

Conditions accept C scalar truth values (arithmetic, enum, pointer/function pointer) and emit ordinary C truthiness. They must not coerce through Titan `boolean` or a Lua guard.

Numeric `for` needs a dedicated C path:

* require a C integer or floating control type;
* check/convert start, limit, and step with C operator/assignment rules;
* evaluate all three once, left-to-right, into raw temporaries;
* keep the visible control read-only;
* use C comparison and addition, accepting C overflow behavior.

There is one semantic gap the draft must settle: ordinary Titan raises when the step is zero, but a raw callback has no implicit error state. The smallest trusted-FFI policy is to document a nonzero-step precondition and emit no Lua check. A stricter alternative is to accept only a statically provable nonzero step. Do not silently use `step >= 0`: zero then selects the positive arm and can loop forever. This needs an explicit language-manual statement/test.

### Returns

A void foreign function permits bare `return` and fallthrough. A nonvoid foreign function requires exactly one adjusted raw-C expression on every path. Reuse conservative nonfallthrough analysis, but against the C signature's single `ret`, not `Type.Function.rettypes` assumptions.

## Dedicated raw-C emitter

Create a small context with only module identity, temporary counter, and local-name counter. It must not contain Lua stack/base/allocation/capture state.

### Declarations

Use `cdeclarator` for every parameter, local, temporary, return, and function declaration. Extend it with a focused root-function-declaration API that accepts parameter identifiers rather than splicing strings around complex declarators. This is important for function-pointer/array typedef parameters and aggregate returns.

Give parameters/locals compiler-owned identifiers (`_foreign_param_1`, `_foreign_local_3`, etc.) and attach them to `Ast.Decl._cvar`. Source names may be C keywords after contextual parsing and must not be emitted directly.

Non-inline definition:

```c
TITAN_SOURCE_LOCAL Ret titan_source_..._titan(Params...) {
    ...
}
```

There is no Lua/strict wrapper, trace registration, CClosure tag, module slot, `_mod`, `_fn`, implicit `L`, or `_init` dependency.

### Sequencing

Materialize:

* binary operands left then right;
* call callee once, then arguments in lexical source order;
* named C arguments in `_named_arg_order`, then reorder the frozen names into formal order;
* all RHS values before assignment stores, while matching the existing Titan rule for when indexed/dotted LHS base/key expressions are evaluated;
* loop bounds/step once before the loop.

Do not rely on C's operand or argument evaluation order. Preserve short-circuit behavior if a logical construct is admitted; do not eagerly freeze both sides of `and`/`or`.

Raw field/index/pointer operations deliberately omit the ordinary coder's `luaL_error` null/bounds checks. A raw function-pointer call likewise omits the ordinary Titan caller's NULL check. This is the supported trusted-FFI boundary, not missing hardening.

## Generated header design

### Linkage

“Local C function” cannot mean literal `static` for every definition because direct source consumers are separate translation units. Use:

* non-inline functions: external C linkage, injective source-private symbol, hidden visibility (`TITAN_SOURCE_LOCAL`);
* eligible constants: `static inline` definition in the generated header, no out-of-line definition.

For each header, emit **all declarations first**, then inline bodies. An inline function may call a later inline/non-inline foreign function; prior declarations make this valid. Do not emit an `extern` prototype followed by `static inline` for the same function because that is a linkage conflict. The declaration for an inline function must itself have static linkage.

The mandated `static inline` rule means taking the address in two translation units can yield different pointer identities. That consequence should be documented and tested/accepted; do not add a canonical out-of-line identity behind the plan.

### Contents and include order

A generated header should contain:

1. a stable generated-file ownership banner;
2. an injective include guard;
3. the module's direct foreign includes in AST order;
4. any supplemental origin headers required by rendered signature/body C types, using the same `types.c_ffi_includes` collection and deterministic deduplication as `coder.generate`;
5. generated headers for direct source imports that actually own foreign members, in AST import order;
6. the visibility macro if it has not already been factored into a shared prefix;
7. all prototypes;
8. all eligible `static inline` bodies.

The supplemental-origin step is necessary. Module A can use a local C alias exposed by direct source module B even if B has no foreign function and therefore no generated header. A's prototype still needs B's original C header.

Use normalized quoted include rendering and an absolute physical generated-header path (or a correctly computed relative path from the including header). Absolute is the smallest robust choice because source roots can be external and no generated-header `-I` search path exists. This is a trusted project path; use the existing C-string/include renderer rather than new adversarial path machinery.

Include the owning header from its generated `.c` so the C compiler checks prototype/definition agreement. Preserve the checked foreign-header context order: direct C imports should not move behind generated source headers and acquire unvalidated macro effects. Factor a common include planner rather than maintaining two subtly different orders.

### Exact inline classification

After successful checking, mark a function inline only when its root block is exactly:

* zero or more direct `StatDecl`s followed by one one-expression `StatReturn`; or
* that prefix followed by one `StatIf` with one `then`, a required `else`, and exactly one one-expression return in each branch; or
* that prefix followed by one one-arm/no-else `StatIf` whose body is exactly one one-expression return, followed by exactly one one-expression return.

No nested declarations, call/assignment statement, extra arm, bare return, or additional statement qualifies. Emit void functions out of line because the three specified shapes all return an expression. Perform classification once and share the annotation between header and `.c` generation.

### Driver orchestration

The header path is derived from the **final physical native output**, not merely `source.main`/`mod.filename`:

```text
flat foo.titan       -> foo.h
folder foo/bar.titan -> foo/bar.h
custom native_output -> same custom stem .h
```

Do not store a provisional header path in loader import info. Generated/test modules can change `native_output` after checking. Instead:

1. finish resolver/finalizer selection;
2. build a module -> header-plan map from final `driver.imported` records;
3. annotate direct source import nodes or pass the map to header/coder generation;
4. preflight all plans;
5. write/remove all headers;
6. only then compile source modules in sorted order.

Header outputs must participate in the same occupied-path graph as source inputs, generated `.c`/`.o`, program/entrypoint, provider `.so`/`.a`/dSYM, shims, and `-X` inputs. Checking only header-vs-header collisions is insufficient.

Refuse to overwrite an existing user-owned `.h`; accept/replace/remove only a file beginning with the exact Titan generated banner. When a module no longer has foreign members, remove a stale banner-owned header but leave an arbitrary same-stem user header untouched. This banner also gives `make clean`/test cleanup a bounded ownership rule; never add `rm titan/*.h` or another broad header glob.

The per-module compile fallback may prepare its one header for API callers outside `titanc`, but the ordinary multi-module CLI must always use the all-header prepass first.

## Function-like C macro alternative

Current preprocessing retains function-like definitions (`args` plus replacement tokens), but `cdefines.register_defines` publishes only supported object-like forms. A macro definition is not a C prototype: it gives arity but no parameter/result types, qualifiers, lvalue/result category, addressability, or evaluation count. `clCvalue`, `uvalue`, and `pvalue` are also type-dependent nested macro expressions rather than simple aliases to declared functions.

A sound future “simple macro” design would need an explicit trusted signature contract and a call-only descriptor distinct from `Type.CFunction`:

1. An annotation or parenthesized same-spelling C declaration supplies the signature. For example, `(clCvalue)` in a declaration avoids invocation, while generated `clCvalue(arg)` still lets the host preprocessor expand it.
2. The registrar verifies an active function-like macro with matching arity and records macro-call-only provenance/redefinition frontier.
3. The checker permits only direct calls, not address decay or first-class function-pointer use; there may be no linkable symbol.
4. Codegen freezes each argument once and emits the public macro spelling. Stringification, token pasting, variadic macros, statement macros, and macros requiring the original token/lvalue form must be excluded because freezing changes their meaning.
5. The host C preprocessor performs expansion; Titan codegen never expands the replacement.

That is considerably more machinery than four wrappers. For this wrap-up, add typed `static inline` wrappers in `titan/ffi.h` for `thvalue`, `uvalue`, `clCvalue`, and `pvalue` (plus the raw-Udata push helper identified in the shim research). `titan/ffi.h` must include `lstate.h` for the nested `gco2*` definitions. Use Lua's actual capitalization: `lmacro_clCvalue`, not `lmacro_clCValue`.

## Exact compiler modification map

| File | Required work |
|---|---|
| `titan-compiler/ast.lua` | Add the two dedicated AST constructors. |
| `titan-compiler/parser.lua` | Disambiguate top-level foreign declarations from foreign imports; parse the foreign function-pointer type; add committed local-form diagnostics. |
| `titan-compiler/syntax_errors.lua` | Add only the new committed diagnostic labels; reuse existing function/list/end labels. |
| `titan-compiler/checker.lua` | Add type lowering/signature validation; top-level reservation/staging/body dispatch; source-member marker; direct-C designator recognition; foreign literal/context rules; dedicated statement checker; restricted visibility; inline annotation. |
| `titan-compiler/types.lua` | No new Type constructor. Confirm `source_module_prefix_layout` continues to ignore marked CFunction members; reuse C equality/include/scope helpers. |
| `titan-compiler/foreigntypes.lua` | No parallel conversion model. Possibly factor a reusable C function-signature validation/parameter-adjustment helper. |
| `titan-compiler/cdeclarator.lua` | Add a structural root function declaration renderer accepting parameter identifiers. |
| `titan-compiler/coder.lua` | Add source foreign naming/reference lowering; raw body emitter; header emitter/include planner; external-symbol reporting for non-inline definitions; include the owning header. Do not modify `codefuncdec` into serving both ABIs. |
| `titan-compiler/driver.lua` | Plan/preflight/write/stale-remove generated headers; pass final physical paths; prepare all before compile; preserve fallback API behavior. |
| `titanc` | Insert the all-header plan/preflight/write phase before the sorted `compile_module` loop and include header outputs in both standalone/library output validation. |
| `Makefile`, `spec/support/clean_generated_test_artifacts.sh` | Remove only banner-owned generated headers and explicitly known standard outputs. Preserve author headers. |
| manuals/indexes | Add user/implementation chapters and link/update FFI/artifact documentation. |

### Audit of existing `TopLevelFunc` checks

Do not globally replace every check with “ordinary or foreign.” Audit by purpose:

* **Add foreign:** top-level naming/duplicates/reservation; callable signature pass; body dispatcher (to the dedicated checker); function-declaration assignment protection; direct-call/named-call recognition; source-module member construction; non-inline external-symbol preflight.
* **Do not add foreign:** `checker.has_main`; public/exported C-type/local-nominal validation (foreign is never public); closure `_valref`; public/source module-userdata closure slots; Lua/strict wrappers; function-tag publication; module member maps; trace entries for Titan native frames; `codefuncdec`.
* **Use the direct-C reference helper, not tag widening:** multi-assignment call-result classification, generic-boundary classification, `ExpVar` contextual function decay, call code selection, and coder direct-call detection.

## Focused tests

A feature of this size merits topical specs rather than expansion of generic checker/coder files.

### Parser (`spec/parser_spec.lua`)

* `foreign function` with zero/one result and ordinary block AST.
* `foreign () -> ()`, one result, nested pointer/callback shapes.
* Existing `local x = foreign import` remains unchanged.
* Clean diagnostics for both forbidden local spellings, missing name/parenthesis/end, malformed result lists.
* Variadic/flexible/multiple shapes parse far enough for checker-specific rejection.

### Checker (`spec/checker/foreign_functions_spec.lua`)

Positive:

* type constructor is exactly `CPointer(CFunction)` with `abi=false`;
* declaration is direct `CFunction`, void mapping and parameter adjustment;
* imported typedefs, complete aggregates, function pointers, enums;
* forward/mutual foreign calls and named direct calls;
* direct source call/address through alias;
* literals become C `_Bool`/`int`/`double`/`const char *`/contextual NULL;
* all allowed statements and raw C expressions;
* foreign function absent from public members but present as marked source member;
* source callback aliases retain required C include/scope provenance.

Negative table:

* every Titan-only parameter/result/local category (`value`, Titan numeric/string/bool, Option, Array/Map, nominal, Titan Function);
* `COwned`, void parameter, returned array/function, incomplete by-value aggregate;
* multiple/flexible/variadic declaration and type constructor;
* duplicate parameters, missing nonvoid return, wrong return arity;
* ordinary current/imported variables/functions/nominals, transitive source capability, binary import;
* `for in`, case, raise, catch, defer, constructor, lambda, bound method, dots, concat, `.new/.new_array`;
* casts to/from `value` or other Titan types;
* untyped `local p = nil` and out-of-range default C integer literal;
* dynamic/zero-step numeric-for policy.

### Coder/runtime (`spec/coder/foreign_functions_spec.lua`)

* Imported C harness invokes a generated callback and observes its result.
* Generated raw signature contains none of implicit `lua_State *L`, `_mod`, `_fn`; no Lua/strict entry or closure slot is produced.
* Raw calls, pointer calls, struct/union field/index, address formation, numeric casts/operators, assignment sequencing, loops/conditionals.
* Function-pointer/`void *` cast uses `titan_cast_func` where required.
* Named C arguments preserve lexical evaluation order.
* NULL pointer call in a foreign body has no manufactured `luaL_error` (do not execute UB; inspect generated C).
* A consumer whose name sorts before its producer proves the all-header prepass.
* Same-module and cross-module callback address lowering uses the exact source-private symbol.
* All three inline shapes are `static inline`; near misses remain out of line; declarations precede bodies; mutual references compile.
* Decide/test per-TU pointer identity consequence for inline functions.
* Complex callback declarators compile (pointer return, pointer-to-function parameter, typedef array parameter adjustment).
* Folder contributor declaration produces one header beside the canonical folder main, with contributor `#line` attribution.
* `--no-line-directives` applies consistently to header bodies.

### Driver/artifacts

Extend `spec/driver_spec.lua`/the relevant topical coder provider specs for:

* final `native_output` path rather than source-main path;
* header-vs-header and header-vs-input/`.c`/`.o`/program/provider/archive/shim collision rejection;
* refuse user-owned `.h`, replace/remove banner-owned `.h`;
* no header for a module with no foreign member;
* both standalone and library paths run the prepass;
* a combined `.so`/`.a` where a public Titan function internally calls a source foreign function works through DSO and archive consumers, while a later binary Titan import cannot name the foreign member;
* cleanup preserves an author-written header.

The existing source-import visibility specs should get one focused direct-vs-transitive-vs-binary foreign-member matrix. Existing `types_spec.lua` CFunction/include-provenance cases can be extended only if the new composed callback reveals a missing law; do not duplicate them wholesale.

## Documentation and ABI

This is user-visible syntax/semantics, so implementation must add and link both manuals in the same change. Document:

* declaration/type syntax and pointer-vs-designator distinction;
* exact restricted body/visibility/literal rules;
* trusted raw C behavior, lack of implicit rooting/error/null/bounds checks;
* numeric-for zero-step decision;
* generated header/linkage/inline pointer-identity consequence;
* direct-source-only availability and binary absence.

The syntax and source-only generated headers alone require **no compiled-module
ABI bump**: they reuse `Type.CFunction`, add no serialized member, and change no
module-userdata prefix. The full wrap-up does require the separately researched
ABI boundary if the existing `titan_uvshim_*`/coroutine native symbols are
removed. Do not retain compatibility wrappers or migration machinery merely to
avoid that clean-start bump.

## Suggested implementation order

1. AST/parser and signature lowering tests.
2. Source-member provenance plus ordinary Titan direct call/address tests.
3. Dedicated body checker and literal/C-plan tests.
4. Raw emitter for straight-line calls/returns, then control flow and sequencing.
5. Pure header renderer and exact inline classifier.
6. Driver final-path/output preflight and all-header prepass.
7. Cross-TU/provider/cleanup tests.
8. Typed Lua macro wrappers and stdlib shim migration only after the compiler surface is stable.
9. Manuals, roadmap, ABI/native-contract updates as part of the same completed change.

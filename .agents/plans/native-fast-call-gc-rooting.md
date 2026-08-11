# Native Fast-Call GC Rooting Follow-up

Status: **implemented and locally validated.**

This follow-up starts after the contextual lambda-result inference restoration.
It records the intended Titan/Lua-stack invariant before any code changes so the
implementation does not conflate GC roots with Lua-convention argument passing.

## Maintainer invariant

Titan places a GC object in a traced Lua-stack slot in exactly two native-path
situations:

1. **Immediately after allocating it**, establishing the allocation's initial
   root. Later Lua-stack reallocation preserves that root because the relocated
   stack contains the same traceable object reference.
2. **Immediately after receiving it as a Titan native-call result**, establishing
   a new root before later work can collect it. A transitive callee may have
   allocated the object, and the callee's original allocation root can lie above
   the restored caller stack top after return.

A separate third situation places **general values**, not merely GC objects, on
the Lua stack to invoke a callable through the Lua calling convention. Those
slots are the callee's actual arguments; this is argument transport, not a
native-call tracing protocol.

The Titan native calling convention passes arguments in C formal parameters.
It must not copy fixed arguments, receivers, first-class callees, or static
variadic arguments into Lua-stack slots merely to keep them live through the
call. A stack slot used as a GC root is write-only from Titan's perspective;
generated Titan code continues to use the native C value, never that slot, as
the value's home.

## Audit boundary

Audit the complete native fast path, including:

- direct positional and named calls;
- methods, Interface dispatch, and receivers;
- first-class exact-Titan fast calls versus Lua/generic fallbacks;
- fixed/static variadic inputs and forwarded open runs;
- callable and Interface adjustment adapters;
- expression-order materialization versus tracing roots; and
- fixed/flexible native result handoff.

In particular, review the caller-owned “activation root” machinery and any
older Interface-adapter input anchoring. Treat the latter as a bug if it copies
native inputs into stack slots for tracing. Preserve instead:

- ordinary C temporaries needed only for lexical evaluation order;
- immediate roots for every fresh allocation;
- post-native-call roots for returned GC objects and live open result runs;
- stack rebasing after operations that can relocate stack slots; and
- Lua-convention argument setup on genuinely Lua/generic call branches.

## Implemented inventory

| Boundary | Native representation | Traced publication |
| --- | --- | --- |
| positional/named fixed input | direct C expression or `coder._freeze_code` C temp | none |
| method/Interface receiver | one C temp | none |
| first-class callee and exact fast-path args | C `TValue`/typed temps | none |
| static/open input-vararg elements | raw typed C array/descriptor | none; each element borrows existing provenance |
| Interface/callable conversion source | C temp | none |
| freshly allocated record/string/closure/Interface/callable destination | native pointer/value | immediate initial allocation root |
| live fixed GC result from a native Titan call | raw ABI holder, then caller value | immediate caller result-source/home root after rebasing |
| live open GC result run | caller-owned raw C backing | complete immediate parallel traced range after validation |
| branded-strict or genuine-Lua call | VM stack frame | actual carrier/callee and argument transport slots |

`materialize_code` remains rooted for semantic locals, assignments, pending
returns, container construction, and other owning sinks. Native input builders
instead opt into `coder._freeze_code`; this split preserves lexical evaluation
order without changing ownership. Callable/Interface adapter input-source
inventories remain canonically empty. Their result-source inventories now cover
every live GC-bearing fixed/open result, even for identity actions; destination
inventories cover only fresh allocations.

The no-copy model intentionally does not extend the lifetime of a raw C formal
if a program destroys that value's sole traced semantic provenance while the
formal is still in use. Supporting that stronger behavior would require the
third call-activation root explicitly rejected by the maintainer invariant; do
not reintroduce it under an allocation/result label.

## Implementation map

- `ordered_call_args`, `named_ordered_call_args`, direct receivers,
  `codevaluecall`, adjusted fixed/open inputs, and static/open vararg builders use
  C-only freezes on native paths.
- Interface wrapper construction and bound-method construction keep their
  sources/receivers in C; they retain only real upvalue transport and the fresh
  destination root.
- Structural Option guarding uses C temporaries; the successful guard does not
  allocate, and its enclosing sink owns any required semantic/result home.
- Ordinary fixed/open result handoff and callable/Interface adapters publish live
  GC results immediately after return/rebase. Raw descriptors and buffers remain
  non-roots.
- Lua/generic and strict relays still push complete actual call frames.

## Validation evidence

Generated-C assertions now pin every boundary in the inventory:

- positional and named C freezes preserve lexical order without input stores;
- ordinary/Interface receivers and first-class callees stay in C;
- exact first-class calls use C values while strict/Lua branches push complete
  VM frames;
- static and forwarded input-vararg descriptors contain no tracing-only element
  stores;
- Interface and bound-method construction have no preliminary source/receiver
  root, while the fresh wrapper/closure is published immediately;
- callable adapters have empty input-source stores and publish identity fixed and
  open GC results immediately after the source call and rebase; and
- deterministic finalizer coverage distinguishes initial allocation and
  post-native-call result roots from the removed activation copies.

Local validation from the repository root with the isolated
`/tmp/titan-mascarenhas-callable-adjustment` prefix:

- `luac -p` on all changed Lua files and `git diff --check`;
- eight focused checker/coder files: **388 successes**;
- `spec/support/ci_test_groups.sh compiler` with LuaCov: **2,596 tests** across
  the main, unit, and isolated compiler groups;
- `make titan-stdlib-test`: **186 native tests**; and
- canonical `make test`: **2,710 Busted successes**, followed by **186 native
  tests**, with zero failures/errors.

Manual macOS CI remains waived for this PR; the required fresh Linux graph runs
after push.

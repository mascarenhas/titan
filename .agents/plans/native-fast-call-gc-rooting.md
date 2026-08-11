# Native Fast-Call GC Rooting Follow-up

Status: **maintainer clarification captured; implementation audit pending.**

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

## Required evidence

Before implementation, map every relevant `materialize*`, call builder,
adapter root inventory, generated stack write, and structural assertion to one
of the three legitimate situations above. Then add focused generated-C and
runtime coverage proving that:

- native fixed/receiver/callee/static-vararg inputs create no tracing-only stack
  copies;
- native result objects are rooted immediately on return;
- fresh allocations acquire their initial roots immediately;
- Lua/generic calls still place all required values on the Lua stack; and
- removing the mistaken input roots does not alter lexical evaluation order,
  call adjustment, flexible descriptors, or callable/Interface behavior.

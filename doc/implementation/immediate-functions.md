# Immediately called anonymous functions

A call whose callee is an `Ast.ExpFunction` lowers to a scoped C block in the
containing native function. It does not construct the literal's `CClosure`,
dispatch through `codevaluecall`, or emit native/Lua/strict entries for that
literal. This makes anonymous functions useful as statement-valued expressions
without paying for an ephemeral function object. The source contract is in
[Anonymous functions and closures](../language/closures.md#immediate-calls-as-expressions).

## Eligibility and checked plans

Eligibility follows the checked call shape. Parentheses around a literal retain
`Ast.ExpFunction`; parentheses around the completed call instead produce
`Ast.ExpAdjust`, whose one-result boundary is preserved. A callable cast is a
real conversion, not transparent grouping. Stored function values, returned
function values, bound methods, and named functions retain their usual call
paths.

Checking still sees a complete source function. It determines parameters,
declared fixed/flexible results, captures, return reachability, and argument and
result adjustments before lowering. The consumer's finite/open demand selects
storage and transport; it does not infer a different lambda signature or make
an otherwise invalid call valid. A lambda with neither a return annotation nor
an expected function type still declares zero results. Source bindings and
function boundaries remain available to analysis-only clients.

The coder reuses the existing checked argument and expression-list plans. It
evaluates argument expressions once in their established order, including
surplus effects and spread subjects/bounds, then binds fresh parameter locals.
Parameters are not replaced by their source argument expressions. Missing
arguments already have their checked nil adjustment. Anonymous functions remain
positional-only.

## Logical functions in one physical frame

The inline body shares the containing C function's temporary-name allocator,
root-slot accounting, allocation tracking, and stack base. It has its own
logical function scope for parameters, input varargs, result destination,
loops, catches, and cleanup. A nonvariadic literal cannot see its caller's
`...`, and a return from the literal cannot return from the containing C
function or run the caller's pending cleanup.

The essential shape is:

```c
lua_Integer result;
{
    if (flag) {
        result = 10;
        goto inline_done;
    }
    result = 20;
}
inline_done: ;
/* consume result */
```

This sketch omits parameters, roots, protected boundaries, and return
adjustments. Result holders and their roots belong outside the body's
disposable scope. Source `return` statements write those holders, run the
cleanup they cross, and transfer control to the inline continuation. Zero-result
fallthrough and permitted nil/flexible fallthrough use the same destination
with the appropriate absent values and zero tail count.

The shared return-lowering path keeps the native ABI destination, pending
cleanup destination, and inline destination distinct. A pending inline return
passes through the literal's cleanup frames; normal completion reaches its
continuation, while a cleanup error replaces the return. Restoring a protected
boundary stops at the literal's logical function boundary. In particular, the
native epilogue's whole-function `L->top.p = _base` and C `return` must not be
used to finish an inline call.

## Demand and the two conversion edges

The call already distinguishes declared results from the consumer-visible
projection. Inline return lowering uses that demand to retain only the needed
transport:

| Demand | Destination behavior |
| --- | --- |
| Zero | Evaluate required source effects and declared-result checks, then continue without publishing a value. |
| Finite | Fill the requested fixed/flexible holders at each return; flexible projections carry their ordinary optional representation. |
| Open | Preserve the actual fixed prefix and flexible run/count with bounded backing storage and traced ownership. |

A finite result destination avoids constructing a general flexible output
descriptor merely to project it after leaving the block. Open demand still
needs an actual count: an explicit nil element and an absent result are
different. A flexible return forwards its remaining inherited budget to nested
producers using the same rules as
[ordinary flexible returns](flexible-returns.md). The 200-element descriptor
limits and finite-versus-open overflow rules remain in force even when a
particular destination uses no descriptor.

Two checked conversions remain semantically distinct:

1. The written return expression becomes the lambda's declared result.
2. That declared result becomes the caller's destination value.

For example, `integer -> float -> value` must preserve a float-tagged value;
composing it into `integer -> value` would change the result. Count adjustment,
projection, and storage can occur at each return. Caller-side conversions
remain in the continuation when moving them would change evaluation, cleanup,
or catch behavior. A checked numeric conversion, optional force, strict
projection, or allocating Interface/callable adjustment can raise or collect;
it cannot simply be moved inside the literal's protected return path.

All written return expressions and required declared-result adjustments finish
in their existing order before cleanup. Thus, if a lambda returns `(value,
integer)` and the caller wants integers, evaluating its second result precedes
the caller's strict projection of the first. A projection failure belongs to
the caller's catch, after the literal's cleanup has completed.

Discarding preserves the existing fixed/flexible distinction. Fixed declared
results still perform observable conversions even when unused. Once a
flexible-tail budget is exhausted, raw written expressions still execute but
their checker-inserted tail adjustments may be skipped. Written `as` casts are
source evaluation and remain observable under zero demand. Spread subjects
and explicit bounds likewise evaluate once even when no elements are retained.

## Captures, roots, and protected control flow

The inline body accesses captures through their existing value or shared-cell
locations, including captures reached through an enclosing real closure. It
does not populate ephemeral closure upvalues. Existing capture boxes can remain:
removing the immediately called closure does not prove a captured cell is unused
by sibling or nested escaping closures. Real nested closures still allocate,
receive fresh mutable parameter/local cells for each dynamic invocation, and
emit their own callable entries.

GC-bearing result holders are traced before any later expression, cleanup,
stack growth, or allocating conversion can collect them. Open backing arrays
and descriptors are raw C storage, never roots; their live elements require
the ordinary traced result ownership. Roots reserved for an inline result
outlive the body's local scope. Captured-cell writes and publication into real
escaping closures retain their normal barriers.

At the inline continuation, the argument/body root range is cleared after the
literal's cleanup finishes. Demanded result roots sit below that range and
remain live for the consumer. Open runs expose suffix roots consistent with
their finite prefix and count, so ordinary consumer cleanup releases the whole
published suffix without retaining discarded values.

Physical-frame analysis must visit eligible inline bodies. Their protected
regions participate in the containing C function's `setjmp` spilling rules,
and their allocations participate in caller loop GC accounting. Ordinary
noninlined lambdas still own separate C activations. The coder preserves the
logical source-function boundary while accounting for these physical effects,
including GC polls needed after removing closure construction and native entry.

Generated `#line` attribution retains the original source filename and line.
The containing native function may supply the traceback frame; no synthetic
anonymous frame is required. Escaping closure entry points and the public
callable ABI are unchanged, as is `LANGUAGE_SERVER_API_VERSION = 1`.

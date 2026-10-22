# Immediately called anonymous functions

A call whose callee is an `Ast.ExpFunction` lowers to a scoped C block in the
containing native function. It does not construct the literal's `CClosure`,
dispatch through `codevaluecall`, or emit native/Lua/strict entries for that
literal, so an anonymous function can serve as a statement-valued expression
without an ephemeral function object. The source contract is in
[Anonymous functions and closures](../language/closures.md#immediate-calls-as-expressions).

The lowering is `codeimmediatecall` (`titan-compiler/coder/immediate.lua`),
reached from the call dispatcher in `coder/calls.lua`; eligibility is
`coder._immediate_function` (`coder/flow.lua`).

## Eligibility and checked plans

Eligibility follows the checked call shape. Parentheses around a literal retain
`Ast.ExpFunction`; parentheses around the completed call instead produce
`Ast.ExpAdjust`, whose one-result boundary is preserved. A callable cast is a
real conversion, not transparent grouping. Stored function values, returned
function values, bound methods, and named functions keep their usual call
paths.

Checking still sees a complete source function. It determines parameters,
declared fixed/flexible results, captures, return reachability, and argument and
result adjustments before lowering. The consumer's finite/open demand selects
storage and transport; it does not infer a different lambda signature or make
an otherwise invalid call valid. A lambda with neither a return annotation nor
an expected function type declares zero results. Source bindings and function
boundaries remain available to analysis-only clients.

The coder reuses the checked argument and expression-list plans
(`coder._codeadjustedfixed`). It evaluates argument expressions once in their
established order, including surplus effects and spread subjects/bounds, then
binds fresh parameter locals; parameters are never replaced by their source
argument expressions. Missing arguments already have their checked nil
adjustment. Anonymous functions are positional-only.

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
        goto _immediate_done_1;
    }
    result = 20;
}
_immediate_done_1: ;
/* consume result */
```

This sketch omits parameters, roots, protected boundaries, and return
adjustments. Result holders and their roots are declared outside the body's
disposable scope. Source `return` statements write those holders, run the
cleanup they cross, and jump to the continuation label. Zero-result fallthrough
and permitted nil/flexible fallthrough use the same destination with the
appropriate absent values and zero tail count.

Return lowering (`coder/statements.lua`) distinguishes three destination kinds:
`direct` (the native ABI outputs), `pending` (a finally frame's saved values),
and `inline` (this continuation). `codeimmediatecall` installs the `inline`
destination with its label and a `boundary_floor` equal to the current depth of
`ctx.protected_boundary_stack`. A pending inline return passes through the
literal's cleanup frames, then `coder._finish_immediate_return` copies the
saved values into the holders; a cleanup error replaces the return. Restoring
protected boundaries stops at that floor. The native epilogue's whole-function
`L->top.p = _base` and C `return` must never finish an inline call.

## Demand and the two conversion edges

The call distinguishes declared results from the consumer-visible projection.
Inline return lowering uses that demand to keep only the needed transport:

| Demand | Destination behavior |
| --- | --- |
| Zero | Evaluate required source effects and declared-result checks, then continue without publishing a value. |
| Finite | Fill the requested fixed/flexible holders at each return; flexible projections carry their ordinary optional representation. |
| Open | Preserve the actual fixed prefix and flexible run/count with bounded backing storage and traced ownership. |

A finite destination avoids building a general flexible output descriptor only
to project it after the block. Open demand still needs an actual count, because
an explicit nil element and an absent result differ. A flexible return forwards
its remaining inherited budget to nested producers as
[ordinary flexible returns](flexible-returns.md) do; the descriptor limits and
finite-versus-open overflow rules apply even when a destination uses no
descriptor.

Two checked conversions remain distinct:

1. The written return expression becomes the lambda's declared result.
2. That declared result becomes the caller's destination value.

For example, `integer -> float -> value` must preserve a float-tagged value;
composing it into `integer -> value` would change the result. Count adjustment,
projection, and storage can occur at each return. Caller-side conversions stay
in the continuation when moving them would change evaluation, cleanup, or catch
behavior: a checked numeric conversion, optional force, strict projection, or
allocating Interface/callable adjustment can raise or collect, so it cannot
move inside the literal's protected return path.

All written return expressions and required declared-result adjustments finish
in order before cleanup. If a lambda returns `(value, integer)` and the caller
wants integers, evaluating the second result precedes the caller's strict
projection of the first, and a projection failure belongs to the caller's
catch, after the literal's cleanup has completed.

Discarding preserves the fixed/flexible distinction. Fixed declared results
still perform observable conversions when unused. Once a flexible-tail budget
is exhausted, raw written expressions still execute but their checker-inserted
tail adjustments may be skipped. Written `as` casts are source evaluation and
remain observable under zero demand. Spread subjects and explicit bounds
evaluate once even when no elements are retained.

## Captures, roots, and protected control flow

The inline body accesses captures through their existing value or shared-cell
locations, including captures reached through an enclosing real closure; it
populates no ephemeral closure upvalues. Existing capture boxes can remain,
because removing the immediately called closure does not prove a captured cell
is unused by sibling or nested escaping closures. Real nested closures still
allocate, receive fresh mutable parameter/local cells for each dynamic
invocation, and emit their own callable entries.

GC-bearing result holders get reserved slots (initialized to nil) before the
body runs, so they are traced before any later expression, cleanup, stack
growth, or allocating conversion can collect them. Open backing arrays and
descriptors are raw C storage, never roots; their live elements require the
ordinary traced result ownership. Captured-cell writes and publication into
real escaping closures keep their normal barriers.

At the continuation, the argument/body root range is cleared after the
literal's cleanup finishes. Demanded result roots sit below that range and stay
live for the consumer. Open runs expose suffix roots consistent with their
finite prefix and count, so ordinary consumer cleanup releases the whole
published suffix without retaining discarded values.

Physical-frame analysis visits eligible inline bodies: their protected regions
participate in the containing C function's
[setjmp spill rules](error-handling.md#setjmp-sensitive-localparameter-spills),
and their allocations participate in caller loop GC accounting, including GC
polls needed after removing closure construction and the native entry.
Ordinary lambdas keep separate C activations.

Generated `#line` attribution keeps the original source filename and line. The
containing native function supplies the traceback frame; there is no synthetic
anonymous frame. Escaping closure entry points and the public callable ABI are
unchanged.

## Standard-library use

The standard library uses immediate calls to compute values such as
`math.randomseed`'s seed pair, reflection descriptor selection
(`titan/reflect.titan`), JSON descriptor searches (`titan/json/decoder.titan`,
`titan/json/writer.titan`), and spawn stdio preparation (`titan/os.titan`).
These sites pass their inputs explicitly and return the selected values
instead of mutating captured placeholders. Optional result slots keep explicit
annotations where absence is meaningful. Stored callbacks and returned
iterators remain ordinary closures.

An immediate call keeps the cleanup boundaries of the code around it. Lua source
loading (`titan/lua/lua.titan`) keeps the file's close in the enclosing scope,
and TLS context cleanup (`titan/ssl.titan`) stays outside the expression that
selects the context. The inline function boundary must preserve these
relationships even though the generated code shares one C activation.

When converting statement code to an immediate call, compare generated closure
and capture-cell allocation sites against the statement version and run the
owning native standard-library tests against a rebuilt provider. Closure-free
lowering does not make an immediate call faster than the direct statements it
replaces. Do not construct a discarded branch result (as in format grammar
selection) when the expression can return just the chosen result.

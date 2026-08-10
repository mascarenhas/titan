# Closure adjustment wrappers

Titan first class function calls go through a fast path if the types match exactly.
The Titan compiler can help this occur more often by producing wrappers during code
generation whenever it sees a function of type A being passed to a context expecting a
function of type B (where the difference can be `value` holes or parameter/return
type adjustment, since this happens during code generation the typechecker has already
proven the two function types are compatible).

In the typechecker, whenever a non-exact function type check is done (for example,
in a call site, or passing a function value around), the checker should insert
an explicit cast node to guide the code generator.

The code generator should use these cast nodes to generate synthetic
wrappers that adapt the signatures. These synthetic wrappers affect only
Titan exact entry points, the generic and Lua entry points are reused from
the function being wrapped copied. The generated native entry point does
adjustment and coercion on arguments and return values. The `#line` declarations
in this wrapper should point to where the cast node position.

This should increase the hit rate of exact call sites for first-class functions,
and remove the need of existing explicit wrappers and non-idiomatic code
like Task functions that do not need to return anything but still declare
a `: value` return and `return nil` just to avoid a generic call path.

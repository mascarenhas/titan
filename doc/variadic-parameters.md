# Variadic parameters

> **Historical design note.** This unindexed document records the original
> variadic-parameter design, including the pre-0.10 inline descriptor layout
> and the old strict finite-truncation rule. It is not the current language or
> implementation reference. See
> [Variadic parameters](language/variadic-parameters.md),
> [Flexible returns](language/flexible-returns.md), and
> [Variadic parameter internals](implementation/variadic-parameters.md) for the
> shipped semantics and caller-owned descriptor representation.

## Overview

Non-first-class (not a true value that can be captured by closures and used in any place a regular
value could be), purpose is to have a lightweight mechanism that avoids the introduction of a new
full-blown slice type.

## Syntax

Declaring a vararg parameter: `function foo(x: <type>, y: <type>, ...: <type>)`, `function (x: <type>, y: <type>, ...: <type>)`

Always has to be the last parameter. No optional name (divergence from Lua 5.5).

Usage through the special `...` expression, in the syntax it is both a new <explist> case
and `, ...` is an optional trailer for the other `explist` case. There is also the
special `#...`  and `...[<exp>]`, which are both new <simpleexp> cases.

Intended usage:

* Trailing part of expression list (`f(x, y, ...)`, `return ...`, `return 2, ...`, `{ ... }`, `{ 'foo', ... }`)

* Taking the size of the vararg (`#...`)

* Getting the ith element of the vararg (`...[i]`), 1-based

New parser check limits parameter lists and expression lists to 100 elements (have a new
LIST_LIMIT constant in the parser).

## Type checking and semantics

This is not a first-class value, so type-checking is similar to how expression lists
are checked, with these nuances:

1. An expression list containing `...` can adjust upwards to the number of elements the context
expects, with `...` producing as many `t?` elements as needed, but this means that if you use,
for example, `2, 3, 5, ...` in a context expecting two values it is still a compile-time error.

2. When used in an array constructor it is enough that the type is compatible with the array element
type. Type inference (using `...` where the context is not already expecting a type)
works as expected for the simple case `local x = {...}` which will infer the type
of `x` as `{t}` assuming that the variadic parameter is `...: t`. For the case `local x = { e1, e2, ... }`
typing starts from the type of `...` and goes backwards checking the types of the static elements against
that type.

3. The `...[<exp>]` form needs `<exp>` to be compatible with `integer` (with all the usual rules for
coercion), and has type `t?` where `t` is the declared type of the vararg parameter.

4. Use of `...` is valid only in the function that declares it as a parameter, does not extend to
inner functions (of course the inner functions have their own `...` parameters)

5. Declaring `...: nil` is forbidden, since it has no practical use

## Runtime representation

At runtime `...` is always a **statically-allocated** struct of one of these types (following
`ctype`):

```
struct TitanVargInteger {
    lu_byte n_args;
    lu_byte start;
    lua_Integer args[];
}

struct TitanVargFloat {
    lu_byte n_args;
    lu_byte start;
    lua_Number args[];
}

struct TitanVargBooolean {
    lu_byte n_args;
    lu_byte start;
    int args[];
}

struct TitanVargString {
    lu_byte n_args;
    lu_byte start;
    TString* args[];
}

struct TitanVargArrayOrMap {
    lu_byte n_args;
    lu_byte start;
    Table* args[];
}

struct TitanVargValueOrNominalOrOptionOrFunction {
    lu_byte n_args;
    lu_byte start;
    TValue args[];
}
```

The vararg parameter in the native function entry is a pointer to one of these struct types.

A fresh vararg when calling a variadic function with a static argument list always has `start == 0`,
`n_args` the number of arguments that are going into the variadic part. Since this is statically known the
struct can be **statically allocated (in the stack)** to have exactly that number of elements in `data`.
So in this case the pointer passed to the callee is to the stack, not the heap.

This is safe even for collectable objects because these objects are already anchored to the GC via the Lua
stack by the caller.

For the generic (non-Titan entry point) call path the arguments are pushed to the Lua stack, as usual, and no
struct is needed.

A `...[<exp>]` expression gets compiled to a bounds check (with a TITAN_LIKELY annotation that it is expected to pass)
and an access to the `args` array using `start + index` as an offset.

How passing `...` to another variadic function works depends on details of the call site, for native call
sites this is how it works:

1. The static part of the argument list has the same number of elements as the static parameters of the
variadic function (`f(a,b,...)` to call `function (x,y,...)`, and the type of the underlying struct matches.
This is the simplest case, where we just pass the pointer along to the new callee.

2. The static part of the argument list is smaller than the static parameters of the variadic function
(`f(a,...)` to call `function (x,y,...)`), and the type of the underlying struct matches. This is
also simple, we treat the missing static elements as `...[i]` expressions, and then adjust the `start`
for the struct before calling, saving the current value to adjust it back after the call.

3. Other cases (non-matching types, static part of argument list bigger than static parameters) need to
allocate a new Udata0 with the new struct in the "udatamem" portion of this userdata. The userdata is
anchored in the Lua stack for GC tracking, but only the struct (after copying the arguments to it)
is passed to the callee.

For generic call sites we fall back to pushing all of the struct elements to the Lua stack.

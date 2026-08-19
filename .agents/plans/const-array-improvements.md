# const array improvements

These combined provide a lightweight way of writing `map`-like functions that can
be "polymorphic" on the type of array they traverse (since they do not mutate it)
and also can return a mutable array that can be safely turned into a const
one in-place.

```
function map<A,B>(array: const? {<A>}, f: (A, integer) -> B): {B}
  local mapped: {B} = {}
  -- in reverse to do a single resize
  for i = #array, 1, -1 do
    mapped[i] = f(array[i])
  end
  -- mapped does not escabe, so {B} is tagged with linear=true
  return mapped
end
```

```
local xs: const {integer} = {1,2,3}
-- the array returned by map can be frozen in-place
local ys: const {string} = map(xs, string.tostring)
```

## `const? <type>` arrays (maybe const arrays)

This is intended to be used in functions that do not need to mutate an array argument, but
want to be able to receive either a const or a mutable array. This type does not
have a representation by itself, since it is represented by the underlying const or mutable
array.

Like a const array, writes to a `const?` array are type-checking errors, but:

1. A regular mutable array can be used in a context that expects a `const?` array with
a consistent element type (per gradual typing consistency), so you can pass a `{value}`
to a `const? {integer}` constant, or `{string}` to `const? {value}`, or `{(integer) -> string}`
to `const? {(integer) -> value}`, just to give some examples.
2. The same applies to const arrays, so a `const {integer}` can be used in a context that expects
`const? {value}`, and so on.
3. The converse is **not** true, you cannot use a `const?` array in a context that expects
a mutable array or a const array. You can do an explicit cast (`as`) to a mutable or
const array of a consistent element type, but this generates a tag (metatable) check at runtime
and may raise.
4. Coercions from `const?` arrays to `value` are automatic (and always succeed because it
just boxes the underlying array), casts from `value` to a `const?` array are also automatic,
checking for the presence of either the mutable or const array metatable.

Note that 1 and 2 have no explicit cast, since it is the exact same underlying value (the backing 
`Table*`), just being interpreted differently by the type system. Rules 3 and 4 guarantee that
you cannot turn a const array into a mutable array, or vice-versa, by going through `const?`.

The surface syntax for this type is what has been proposed here, with the `?` token immediately
following `const`.

## linear flag on returned mutable arrays

There is already machinery to do a rough analysis on a mutable array value to check if it
did not escape, so that it can be turned into a const array in-place. This adds a `linear`
boolean flag to the mutable array type (not expressible in the surface syntax), and
on `return` expressions runs the analysis on returned mutable arrays, setting the flag
on the array type in the function return type (which should be fresh instance of
the type, so the flag does not accidentaly end up annotating other unrelated values).

Encountering an array type with this flag during typechecking should always consume it
(creating a new type without the flag); the interesting cases are:

1. When a value with this type it is used in a context that expects a `const` array,
it lets the compiler not do the copy, freezing the array in-place.
2. When a value of this type is used as an expression in a return expression list,
it propagates the `linear` flag to the function return type.

The `return` rules only apply to first-order functions (module functions, record/union
functions, record/union methods) for direct calls. The `linear` flag does not propagate 
to the first-class function type in case these functions are used as values.

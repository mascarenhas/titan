When reviewing the code and docs I noticed some smaller issues to fix:

1. Both documentation and code is using explicit type annotations that obscure some of the gains from the new generics. Take this example from the doc/quick-tour.md:

```
function total(scores: {string: integer}): integer
  local result = 0
  for _name: string, score: integer in iteration.pairs(scores) do
    result = result + score
  end
  return result
end
```

The `string` and `integer` declarations in the `for` control variables are noe needed, because with generics they are inferred as these types:

```
function total(scores: {string: integer}): integer
  local result = 0
  for _, score in iteration.pairs(scores) do
    result = result + score
  end
  return result
end
```

This also uses the Lua/Titan convention of using a bare `_` for unusued variables. Multiple `_` in the same declaration are supported:

```
function visit_holes(values: {value}): integer
  local positions = 0
  for _, _ in iteration.ipairs(values) do
    positions = positions + 1
  end
  return positions
end
```

Fix the other uses of unecessary type declarations (because they are now correctly inferred as specific types because of generics), both in documentation and stdlib code, as well as replacing unused variables with `_`. Please put this in the doc/style-guide.md, too.

2. I think the main `checker/generics_spec.lua` could have more negative tests (tests that expect a typechecking error that is now possible because of generics). For example, in the quick-tour example above, if the programmer wrote `for _, score: string in iteration.pairs(scores) do` the program would not type-check since `string` would conflict with the `integer` coming from the `V` parameter of `iteration.pairs`. This would not be a compile-time error in the non-generic version.

3. The `async.channel` function should have become `async.channel<T>`, I missed that in the draft spec, but it is something you could have caught. Related to this, the stdlib `channel_test.titan` should make an effort of using better generic types.

4. Since `Task<(), t>` is not supported as a way of representing a task that does not return anything, these tasks should use `Task<nil, t>`. A missing or bare `return` should be ok in a function that has the `: nil` return type because of return adjustment. In the same way, `async.run<nil, value>(function () <body without return> end)` should type-check because of adjustment.

# Defer

`defer <statement>` is implemented entirely in the parser. The checker and code
generator have no durable `Ast.StatDefer` node: by the time they see the tree,
each defer has become an ordinary `Ast.StatTry` whose finally block holds the
deferred statement. All runtime semantics (pending actions, boundaries,
allocation-free recovery, and setjmp-sensitive spills) are the `finally`
machinery in [Error handling](error-handling.md#code-generator-overview). This
chapter covers only what is specific to `defer`. The language contract is in
[defer](../language/defer.md).

## Lexer and grammar

`defer` is a reserved word in `lexer.lua`, exported as `DEFER`, so it is
excluded from ordinary `Name` bindings. Contexts that use `AnyName`, such as
member selectors, still accept keyword spellings.

The parser production (`titan-compiler/parser.lua`) is:

```peg
deferstat <- (P DEFER (!DEFER / %{DeferDefer})
                 (!SEMICOLON / %{DeferStatement})
                 statement^DeferStatement) -> deferstat
```

It labels two user-facing failures (messages in `syntax_errors.lua`):

* `defer defer <statement>` is rejected with `DeferDefer`.
* `defer ;` is rejected with `DeferStatement`, because semicolons parse as
  ignored empty statements and would otherwise leave no statement to schedule.

`statement` includes `deferstat`, but the `!DEFER` guard prevents direct
recursive deferral. A `do` block is a normal statement, so `defer do ... end`
is the spelling for multi-statement cleanup.

## Parser lowering

The `deferstat` action (`defs.deferstat`) returns a parser-only marker
`{ _tag = "Parser.Defer", loc = pos, stat = stat }`. It is never part of the
public AST inventory: `defs.simpleblock` captures its statements plus the
optional final `returnstat` as one list and immediately passes it to
`lower_defers`.

`lower_defers` is a single iterative pass. It appends statements to a current
list; at each marker it creates an empty tail block, appends

```lua
Ast.StatTry(defer.loc,
    tail,                                        -- Ast.StatBlock, initially empty
    nil,                                         -- no catch
    Ast.StatBlock(defer.stat.loc, { defer.stat }))
```

to the current list, and makes `tail.stats` the new current list. Statements
before a defer stay in the enclosing block; everything after it lands in the
protected tail. Multiple defers therefore nest with last-in-first-out cleanup:

```lua
defer first()
defer second()
work()
```

becomes roughly:

```text
StatTry(body = { StatTry(body = { work() }, finally = { second() }) },
        finally = { first() })
```

Because the final `returnstat` is in the same list, `defer cleanup(); return x`
becomes a pending return through the finally, not a special case.

`case` adds no lowering path. Every arm and the optional `else` use the ordinary
`block`/`simpleblock` productions, so the generated `StatTry` stays within that
arm and composes with an arm-local `catch` trailer.

## Defer-tail scope

`lower_defers` marks both the synthetic `StatTry` and its tail block with the
private flag `_defer_tail`. It preserves the surrounding statement-list scope
for the protected tail, which matters for `repeat ... until`: the repeat
condition is scoped with the body, so it can reference locals declared in the
tail after a `defer`.

* **Checker** (`Ast.StatTry` in `titan-compiler/checker/statements.lua`): for a
  defer tail it checks the tail in the current block, saves the resulting
  bindings for the code that follows, and temporarily restores the defer-point
  bindings while it checks the cleanup as the sibling finally. Cleanup
  therefore sees bindings that existed at the defer point but not locals
  declared in the tail. The ordinary finally bans on `return` and escaping
  `break` apply ([checker rules](error-handling.md#checker-rules)).
  `checker/declarations.lua` rejects `defer` inside a source-defined foreign
  function with a defer-specific message.
* **Code generator** (`titan-compiler/coder/statements.lua`): `codetry` emits a
  defer tail with `codetransparentblock` instead of a nested C block, and the
  statement dispatcher first calls `predeclare_defer_tail` to hoist the tail's
  local (and spill) declarations ahead of the boundary, so tail locals remain in
  C scope for a following `repeat` condition. Everything else, including
  pending-action dispatch and recovery, is the shared `finally` path.

Deferred cleanup participates in the same setjmp liveness analysis as any
finally; see
[recovery storage](error-handling.md#setjmp-sensitive-localparameter-spills).

## Tests

* `spec/lexer_spec.lua` and `spec/parser_spec.lua` pin the reserved word, the
  lowering shape, `defer do ... end`, LIFO nesting, and direct `defer defer`
  rejection.
* `spec/checker/defer_spec.lua` pins defer-point scope and the inherited
  finally control-flow bans, including repeat-condition scope.
* `spec/coder/defer_spec.lua` pins fallthrough, LIFO execution, return,
  multi-statement cleanup, propagated-error cleanup, and generated-C scope for
  repeat conditions.

# Defer

`defer <statement>` is implemented entirely in the frontend. The checker
and code generator do not have a durable `Ast.StatDefer` node; by the
time they see the tree, each defer has become ordinary `Ast.StatTry`
with a `finally` block.

## Lexer And Grammar

`defer` is a reserved word in `lexer.lua`, exported as `DEFER`, so it
is excluded from ordinary `Name` bindings. Contexts explicitly using
`AnyName`, such as member selectors, still accept keyword spellings.

The parser production is:

```peg
deferstat <- (P DEFER (!DEFER / %{DeferDefer})
                 (!SEMICOLON / %{DeferStatement})
                 statement^DeferStatement) -> deferstat
```

The implementation also labels two user-facing failures:

* `defer defer <statement>` is rejected with `DeferDefer`.
* `defer ;` is rejected with `DeferStatement`, because semicolons are
  parsed as ignored empty statements and would otherwise leave no AST
  statement to schedule.

`statement` includes `deferstat`, but the `!DEFER` guard prevents direct
recursive deferral. A `do` block remains a normal statement, so
`defer do ... end` is the supported spelling for multi-statement cleanup.

## Parser Marker

The `deferstat` semantic action returns a parser-only marker:

```lua
{
    _tag = "Parser.Defer",
    loc = pos,
    stat = stat
}
```

This marker is never part of the public AST inventory. It exists only
inside the `simpleblock` action, which immediately rewrites it.

## Simpleblock Lowering

`simpleblock` captures its statements plus optional final `returnstat`
as one list, then calls `lower_defers`. The first defer in that list is
lowered to:

```lua
Ast.StatTry(
    defer_loc,
    Ast.StatBlock(defer_loc, lower_defers(rest_of_simpleblock)),
    false,
    Ast.StatBlock(deferred_statement.loc, { deferred_statement }))
```

The original statement list before the defer remains in the enclosing
`Ast.StatBlock`; the transformed `StatTry` replaces the defer and owns
the rest of the list. Lowering `rest_of_simpleblock` recursively gives
multiple defers their last-in-first-out shape:

```lua
defer first()
defer second()
work()
```

becomes roughly:

```text
do
    do
        work()
    finally
        second()
    end
finally
    first()
end
```

Because the optional final `returnstat` is captured in the same list,
`defer cleanup(); return x` naturally becomes a pending return through a
`finally`, not a special return case.

`case` does not add another lowering path. Every `when` arm and the optional
`else` use the ordinary full `block`/`simpleblock` productions, so
`lower_defers` runs recursively inside each one. The generated nested
`StatTry` stays within that arm; it cannot cross into a sibling arm, and
arm-local `catch`/`finally` trailers continue to compose through the existing
pending-action machinery.

The parser marks the synthetic `StatTry` and its body block as
`_defer_tail`. That marker is intentionally private to the compiler. It
lets the checker and coder preserve the surrounding statement-list scope
for the protected tail, which matters for `repeat ... until`: Titan keeps
the repeat condition in the body scope, so the condition can reference
locals declared in the tail after the `defer`.

## Checker And Code Generator

The checker sees only `StatTry`, so existing `finally` rules define the
semantics:

* the deferred statement is checked in a sibling `finally` scope, with
  the current block temporarily restored to its defer-point bindings, so
  cleanup can see bindings that existed at the defer point but not locals
  declared in the transformed rest block;
* `return` and finally-escaping `break` are rejected inside deferred
  cleanup;
* a `raise` in cleanup is allowed and overrides the pending action.

The code generator likewise uses the existing `codetry` path. For
`_defer_tail`, it emits the protected tail and synthetic try boundary
without the extra C lexical blocks that a user-written `do ... finally`
would get, preserving any tail locals for a following `repeat` condition.
Normal fallthrough, returns, breaks, and raises are still recorded as
pending actions, the synthetic finally block is emitted, and pending
action dispatch continues exactly as for user-written `finally`. Because
`boundary_recover_open` reads the module-rooted registry-key and
empty-traceback `TString` anchors and clears the registry entries with `nil`
without allocating (and `luaD_closeprotected` wraps any intervening Lua
`__close` metamethods in `luaD_rawrunprotected`), unwinding into a registered
`defer` block after an in-body error (including `LUA_ERRMEM` after emergency
collection) cannot fail in generated recovery before the deferred cleanup
statement begins. Re-inserting a saved trace during post-cleanup `PA_RAISE`
happens only after the current `defer` body has completed, and any enclosing
`defer` or `catch` boundary recovers through the same allocation-free path.

Deferred cleanup participates in the same liveness analysis as a written
`finally`. If an address-exposed non-GC scalar can be changed in the protected
tail and read by cleanup, the actual local/parameter has a volatile C home,
not an ordinary auto plus a stale snapshot. A callee that clears a raw packet
slot and then raises therefore leaves cleanup seeing the cleared slot. This
also applies when an earlier protected region already made the declaration
recovery-sensitive; see
[recovery storage](error-handling.md#setjmp-sensitive-localparameter-spills).

## Tests

Keep these tests close when changing the feature:

* `spec/lexer_spec.lua` and `spec/parser_spec.lua` pin the reserved word,
  parse-time lowering shape, `defer do ... end`, LIFO nesting, and direct
  `defer defer` rejection.
* `spec/checker/defer_spec.lua` pins defer-point scope and inherited
  finally control-flow bans, including repeat-condition scope.
* `spec/coder/defer_spec.lua` pins fallthrough, LIFO execution, return,
  multi-statement cleanup, propagated-error cleanup, and generated-C
  scope for repeat conditions.

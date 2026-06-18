# Open questions for the documentation work

Questions that came up while reconstructing the documentation, each with
the assumption I proceeded under. Please revise/answer inline (e.g. under
each "**Answer:**" heading) and I can rework the affected documents.

## 1. Folder names

**Question:** What should the two documentation folders be called?

**Assumption:** `doc/language/` for the language reference/design and
`doc/implementation/` for the compiler and runtime internals.

**Answer:** Correct.

## 2. Fate of `doc/manual.md`

**Question:** Should the old manual be deleted outright, or kept as a
pointer so existing links don't break?

**Assumption:** Replaced its contents with a short redirect stub pointing
at `doc/language/index.md`. Easy to delete later.

**Answer:** Let's keep it for now.

## 3. Scope of "error handling"

**Question:** The request lists "error handling" among undocumented
language features, but the AST/grammar has no error-handling *syntax*
(no try/catch, no `error` builtin). I take it to mean the runtime error
model: when Titan raises errors (boundary type checks, arithmetic guards,
failed casts and option unwraps), how they propagate, how Lua `pcall`
interacts with Titan frames, and the `titan.backtrace()` machinery added
in PR #257. Is that the intended scope, or was there a planned construct
(e.g. result-style returns over option types) that should be described as
design intent?

**Assumption:** Documented the runtime error model as the "error
handling" chapter, including the option-type idiom (`t?` returns +
`or` defaults) as the language-level way to signal recoverable failures,
and noted richer error handling as an open design area.

**Answer:** Current state is fine, as it refreshes my memory on what I was working and may make me reconstruct what was my thinking at the time.

## 4. The two Lua-5.5 migration reports

**Question:** Should `doc/lua-5.3-to-5.5-internals.md` and
`doc/lua-5.5-migration.md` (written 2026-06-10/11) move under
`doc/implementation/`?

**Assumption:** Left them where they are and linked them from the
implementation index, to avoid breaking fresh links.

**Answer:** Let's keep them where they are for now.

## 5. Documenting known bugs and limitations

**Question:** Should the reference document known defects (e.g. the
pre-existing internal compiler error when a record literal initializes a
module global, the unimplemented float `%`), or only the intended
language?

**Assumption:** The language reference documents intended semantics and
marks unimplemented/partial features as such; a "current limitations"
section in each index collects known gaps so they are not mistaken for
design.

**Answer:** We will tackle these in a future pass, but for now just make sure that all of the limitations documented in the individual chapters are referenced from (and linked) the respective index.md files (I have not seen any documented in the implementation one, and have not checked that all are referenced in the language one).

**Outcome (this session):** Done. `doc/language/index.md`'s "Status and
limitations" was rebuilt as a grouped, fully cross-linked list; a new
"Known limitations and quirks" section was added to
`doc/implementation/index.md` (which had none) linking every
implementation chapter's rough edges. Because the Q8 fixes resolved nine
of the documented limitations, those were *removed* from the affected
chapters and omitted from both indexes (per your follow-up: don't
advertise former bugs); the still-valid limitations were kept and, where
a fix was only partial, narrowed (e.g. the multi-return miscompile now
documents only the argument-list position). A link checker confirms all
370 internal doc links/anchors resolve, and a phrase sweep confirms no
chapter still describes a fixed behavior as broken.

## 6. Normative vs. descriptive voice

**Question:** Should the language reference read as a spec for Titan the
language (normative, implementation-independent) or as documentation of
this prototype?

**Assumption:** Reference-style prose with examples, normative where the
design is settled, but explicitly tied to the 0.5 prototype — it
documents what this compiler does, flagging places where the prototype
diverges from evident design intent.

**Answer:** Good.

## 7. Design-philosophy sourcing

**Question:** The philosophy chapter draws on the 2017 Lua Workshop slides
(Gualandi) and rationale found in PR discussions. Hugo's slides predate
your stewardship and the Pallene fork — is it fair to present those goals
(performance-first, Lua compatibility, AOT) as still being Titan's goals,
with the post-fork divergence (Titan = practical sister language with
records/methods/FFI/modules; Pallene = research vehicle) noted on top?

**Assumption:** Yes — presented the original goals as founding motivation
and described the post-fork direction from the PR record (FFI, maps,
methods, option types, standalone executables) as Titan's own path.

**Answer:** Yes.

## 8. Newly discovered codegen bug — fix, file, or just record?

**Question:** While fact-checking the records chapter, a verifier found a
previously unknown code-generation bug: a single function that builds an
array-of-records constructor **and** a map-of-records constructor **and**
assigns elements into both compiles silently but corrupts memory at run
time (deterministic `free(): invalid size`; a `float`-returning function
came back with a table). Each constructor/assignment context works in
isolation; the bisected trigger requires the combination. Reproduction
sketch (record `P` with one float field):

```lua
record P
    x: float
end

function boom(): float
    local arr: {P} = { { x = 1.0 }, { x = 2.0 } }
    local m: {integer: P} = { [1] = { x = 3.0 } }
    arr[1] = { x = 4.0 }
    m[2] = { x = 5.0 }
    return arr[1].x + m[2].x
end
```

Should I (a) attempt a fix in `coder.lua` (most likely a stack-slot
bookkeeping clash between the constructor temporaries and the assignment
temporaries), (b) just file/record it as a known issue, or (c) leave it
entirely?

The empirical verification pass surfaced more defects of the same family.
The full list found while documenting (all reproduced deterministically;
none introduced by this session; the ones that affect users are
documented as limitations in the relevant chapters):

1. **Memory corruption** combining array-of-records + map-of-records
   constructors with element assignments in one function (above).
2. **Bare multi-return forwarding miscompiles**: `return divmod(13, 2)`
   from a function declared to return two values produces wrong results
   (`6, 0`); the mixed form `return 10, divmod(13, 2)` works.
3. **Unwrapping `T?` to `T` on a plain variable crashes the compiler**:
   `missing template variable FILE` — `coder.lua`'s option-unwrap
   template uses `node.loc.file` where the location field is `filename`
   (and needs `c_string_literal`); the concatenation path dies earlier
   with `invalid node type for coercion to string`. Unwraps via
   indexing/`or` work.
4. **`while`/`repeat` conditions miss the boolean coercion**: option- and
   value-typed conditions generate uncompilable C; numeric conditions
   compile to C truthiness (`0` is false — silently diverges from Lua).
   `if` conditions are correct.
5. **Foreign-pointer truthiness crashes the compiler** (`if not win` on
   an SDL window pointer — the committed `examples/sdl_demo.titan` would
   hit it).
6. **Typedef'd enum constants** imported by the FFI crash the checker
   with `impossible: Enum` when used.
7. **`local a, b = (f())`** (adjusted call in a multi-declaration)
   crashes the compiler.
8. **Float `%`** type-checks but aborts code generation.
9. Latent: the driver's `.so`-vs-source mtime branch compares a number
   with `nil`; the foreign-import error path calls `typeerror` with
   swapped arguments.

**Assumption:** Recorded them here and in the work log, and left the
compiler untouched — this session's mandate was documentation, and the
memory-corruption/codegen fixes deserve their own focused session with
the GC/slot machinery in context. The documentation does not advertise
any of the broken paths.

**Answer:** Do a first pass to fix all of these bugs. Make sure they are captured by new tests to avoid regressions.

**Outcome (this session):** All nine fixed and verified — each repro
compiled and run before/after, plus the full `busted` suite (now **817**
passing, 0 failures) with new regression tests for every case. Fixes:
`coder.lua` (1, 2, 3, 4, 5, 8), `checker.lua` (7, 9B), `foreigntypes.lua`
(6), `driver.lua` (9A). Notes worth keeping:

* **Bug 3** went past the plain-variable case in the original report: the
  `T?`→`T` unwrap now works in *every* position (variable, parameter,
  module variable, record field, **a value returned directly by a call**,
  option-as-index, arithmetic, call argument, concatenation), each with a
  clean `expected … found nil` run-time error. The call-result case was a
  separate `&<rvalue>` defect found while reconciling the docs and fixed
  too.
* **Bug 2** is fixed in both multi-value positions: `return divmod(13, 2)`
  (`codereturn`) and a trailing multi-return call in an **argument list**,
  `add3(10, divmod(7, 2))` (`codecall`). Both were the same
  C-unspecified-argument-evaluation-order hazard, fixed by hoisting the
  call into a temp before the `ExpExtra` reads. All multi-return positions
  now match Lua (a trailing call expands; a non-trailing one is adjusted
  to one value), and the type checker already enforced that contract —
  confirmed empirically: over-/under-supply give clean arity errors and an
  ill-typed expanded value gives a clean type error. (The argument-list
  fix and its follow-up were done after the first nine, at your request;
  the limitation was removed from the chapters and index accordingly.)
* **Bug 9** covered both halves: the driver mtime nil-compare (so
  `.so`-only imports now work end to end — verified by compiling a
  dependency to a `.so`, removing its source, and importing it) and the
  foreign-import `typeerror` swapped-args/`node._pos` crash.

The full details are in [documentation-worklog.md](documentation-worklog.md);
the chapters and both index limitation lists were reconciled to drop the
now-fixed items (see Q5).

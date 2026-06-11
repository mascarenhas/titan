# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Titan is a statically-typed, ahead-of-time-compiled sister language to Lua. This repo is the prototype compiler, written in Lua, that translates `.titan` modules to C and invokes the system C compiler — producing either a shared library per module (loadable from Lua via `require` and from Titan via `import`) or, when exactly one requested module defines `main(args: {string}): integer`, a standalone executable bundling all modules. The language reference is `doc/manual.md`.

## Prerequisites (important — the suite cannot run without these)

- **Lua 5.5.** Both the compiler's own Lua code and the generated C target Lua 5.5 (rockspec: `lua ~> 5.5`). CI (`.github/workflows/ci.yml`) uses hererocks (installed from git master — the PyPI release does not know Lua 5.5) to build a Lua 5.5 + LuaRocks environment.
- **A built Lua 5.5.0 source tree at `./lua-5.5.0`** (gitignored). Generated C includes Lua *internal* headers (`lobject.h`, `lgc.h`, `lvm.h`, ...) and links `lua-5.5.0/src/liblua.a`:
  ```
  wget http://www.lua.org/ftp/lua-5.5.0.tar.gz && tar zxvf lua-5.5.0.tar.gz
  cd lua-5.5.0 && make linux MYCFLAGS=-fPIC    # 'make macosx' on Darwin
  ```
- **Lua deps**: `luarocks make titan-dev-1.rockspec` installs lpeglabel, inspect, argparse, luafilesystem, plus the `titan` runtime-support module (`titan.backtrace()`) that one coder spec requires. Tests need `luarocks install busted`.
- **C toolchain**: `cc` for compilation; the C FFI also shells out to `gcc -dM -E` and `cpp -v` at compile time (POSIX only).

## Commands

```sh
busted                                              # full test suite — MUST run from repo root (all driver paths are relative)
busted spec/parser_spec.lua                         # single spec file
busted spec/coder_spec.lua --filter='for loop'      # single test (Lua pattern on test name)
busted -c -o gtest -v spec/                         # what CI runs (with luacov coverage)
LUA_CPATH="./?.so;$HOME/.luarocks/lib/lua/5.5/?.so;;" busted   # if the 'titan' rock lives in a local rocks tree

./titanc [--print-ast] [-v] [--lua <luasrc>] [--tree <srcroot>] [-l lib1,lib2] <module>...
```

`titanc` takes dot-separated **module names**, not file paths (dots map to directory separators under `--tree`, default `.`). Compiled-module lookup uses `TITAN_PATH_0_5`/`TITAN_PATH` (default `.;/usr/local/lib/titan/0.5`). `-v` prints the exact `cc` command lines. Without the `lua-5.5.0` build, only the pure specs pass (lexer, location, parser, symtab, types, util); `checker_spec` and `coder_spec` need the full setup.

**Gotcha — the installed rock shadows the working tree under busted.** The busted launcher prepends the rocks tree to `package.path` and uses `luarocks.loader`, so once `luarocks make` has installed the `titan` rock, `require "titan-compiler.X"` inside specs resolves to the *installed snapshot*, not your edited files — edits silently don't take effect. Re-run `luarocks make --local titan-dev-1.rockspec` after changing compiler sources, before running busted. (CI does the same: `luarocks make` then `busted`.)

### Lua 5.5 internals conventions in generated C

The coder targets Lua 5.5 internals; keep these idioms when touching templates: stack fields are unions (`L->top.p`, `L->ci->func.p`, `StkId` + `s2v()` to view a slot as `TValue*`); the table array part has no `TValue` slots (read via `luaH_fastgeti`/`luaH_getint` into a local `TValue` holder testing `tagisempty(tag)`, write via `obj2arr`/`luaH_setint`/`luaH_set` — `luaO_nilobject` and `luaH_newkey` no longer exist); booleans carry no payload (`ttistrue`, `titan_setbvalue` from titan.h); `ttypetag()`/`LUA_V*` are the variant tags (old `ttnov` is now `ttype`); records store their backing `CClosure` in the Udata's user value (`uv[0].uv`, created with `luaS_newudata(L, sz, 1)`). Stores of collectable values into `CClosure` upvalues need `luaC_barrier`, table stores need `luaC_barrierback(L, obj2gco(t), v)` — the generational GC makes missing barriers near-deterministic corruption, not a rare race.

## Architecture

Pipeline (all in `titan-compiler/`): source text → `parser.parse` → `checker.check` → `coder.generate` → `pretty.reindent_c` → `driver` writes the `.c` **next to the `.titan` source** and invokes `cc` (`driver.CC`/`driver.CFLAGS`, via `os.execute` with no escaping). `titanc` orchestrates: typecheck everything first, exit 1 with all errors before any codegen, then compile and link.

### The `_tag` / typedecl convention (cross-cutting)

AST nodes (`ast.lua`) and types (`types.lua`) are plain tables created by `typedecl.lua` constructors: positional, arity-checked args producing `{_tag = "Ast.ExpCall", ...}` / `{_tag = "Type.Integer", ...}`. All dispatch is string comparison on `_tag`. `util.make_visitor` **asserts** a handler exists per tag — adding an AST tag means updating every checker visitor (`checkstat`/`checkexp`/`checkvar`/`typefromnode`/toplevel) and the coder's if/elseif chains; adding a Type tag means updating `types.tostring`/`equals`/`compatible`/`serialize` by hand. Group names in `ast.lua` (Exp, Stat, ...) are documentation only — they don't appear on nodes.

### Frontend (`lexer.lua`, `parser.lua`, `syntax_errors.lua`)

Lexing and parsing are fused in one LPegLabel/relabel grammar; `lexer.lua` exports raw LPeg patterns referenced as `%TOKEN` terminals (no token stream). Every AST constructor is auto-injected into the grammar's defs table, so grammar actions like `-> TopLevelFunc` call constructors directly. Every error label used in the grammar (`^Label`, `%{Label}`) or lexer (`lpeg.T`) **must** have an entry in `syntax_errors.errors` or error formatting breaks. The parser is not reentrant (module-global `THIS_FILENAME`, asserted nil on entry). `record` declarations are desugared at parse time into a `TopLevelRecord` plus a synthesized `new` static function.

### Checker (`checker.lua`, `types.lua`, `symtab.lua`)

`checker.check(modname, ast, subject, filename, loader) -> moduletype, errors`; callers test `#errors == 0` (the doc comment claiming a boolean return is stale). Two passes over toplevels: signatures first (duplicates get `node._ignore = true` — later passes must skip these), then bodies. The checker both annotates (`_type`, `_types` for multi-return calls, `_decl` on variable uses, `_used`/`_assigned`) and **mutates** the AST:

- Every legal implicit coercion is materialized as a synthesized `Ast.ExpCast` node (`trycoerce`) **before** `checkmatch` — the coder generates conversions only from ExpCast, and `checkmatch` reports an error if a still-coerceable mismatch reaches it.
- Extra multiple-return values become synthesized `Ast.ExpExtra` nodes appended to `exps`/`args` lists; for-loops get a default step synthesized into `node.inc`.

`checkstat` handlers return a boolean "always returns", used to enforce that non-nil-returning functions return on all paths. Imports go through a `loader` callback (`driver.defaultloader` for real lookup, `driver.tableloader` for in-memory sources in tests); source deps are recursively typechecked, `.so`-only deps recover their interface from the compiled `<mangled>_types` symbol.

**Process-global mutable state** — tests and tools must reset these: `types.registry` (FQTN → `Type.Record`; `Type.Nominal` carries only the FQTN string and resolves through the registry at every use) and `driver.imported` (import cache with a `CIRCULAR_MARK` sentinel for cycle detection).

### Coder and driver (`coder.lua`, `pretty.lua`, `driver.lua`)

`coder.generate(modname, ast, static_deps)` produces one C translation unit as a string — no C AST, just `util.render` templates (`$VAR` substitution, recursive; error on missing keys). Key facts:

- Each Titan function becomes **two** C functions: a raw native-convention one (`RETTYPE f(lua_State *L, CClosure *_mod, params..., out-params for returns 2..n)`; the **caller** anchors GC-able arguments on the Lua stack) and a Lua-stack entry wrapper that coerces arguments and installs the error handler.
- Module state lives in a `CClosure` (`_mod`): upvalue 0 is the Lua-visible module table; further upvalues hold module globals, imported-module closures, and record metatables.
- Generated C must follow the style contract in `pretty.lua`'s header (K&R braces, `/**/` comments never after `{`, braces mandatory) — `reindent_c` is purely heuristic.
- Deps with available `.titan` source are compiled in and statically linked; `.so`-only deps are dlopened at runtime by the generated `_init`. Every compiled module exports `luaopen_<mangled>`, `<mangled>_init` (idempotent), and `<mangled>_types` (serialized interface type, evaluated with `types.lua` as env).
- `titan-runtime/titan.o` is rebuilt lazily by the driver from `titan.c` (dlopen-based module loader, error handler with C backtrace). `titanlib.c` is a separate optional Lua module exposing `titan.backtrace()`.

### C FFI (`c-parser/`, `foreigntypes.lua`)

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; gets system include paths and predefined macros by shelling out to `cpp`/`gcc`), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList). `foreigntypes.convert` maps the results to checker types (`char*` → String, `T*` → ad-hoc `Type.Pointer` tables not made by typedecl); struct/union/enum field handling is still TODO. `typed.lua` (used only by c-parser) is a runtime signature-checking DSL that ships **disabled** — `typed.off()` is the last line; flip to `typed.on()` to debug c-parser type confusion.

## Test suite notes

- `coder_spec.lua` is end-to-end: it generates C, compiles with the real `cc`, and runs the result under `lua-5.5.0/src/lua` via `io.popen`. Artifacts (`test.c`, `test.so`, `./test`, `*.o`) land in the repo root; `after_each` cleans them. Its `setup()` deletes `titan-runtime/titan.o` to force a runtime rebuild. Flip `local verbose = false` at the top to see `cc` command lines and keep generated `.c` files.
- Test helpers that touch the checker/coder must reset shared state first: `types.registry = {}` (and `driver.imported = {}` where imports are involved) — see `run_checker`/`run_coder`.
- Parser/checker specs compare ASTs with a subset assertion (`restrict` + `assert_is_subset`): only fields present in the expected table are compared, so adding new AST decorations doesn't break existing tests. Follow this pattern.
- `TableFormatLevel` (luassert's table-printing depth) is global across spec files, and post-checker ASTs are self-referential — printing one in a failure diff at unlimited depth hangs busted. `parser_spec.lua` raises the depth in `setup()` and restores it in `teardown()`, but a stray `assert:set_parameter("TableFormatLevel", -1)` in its describe body (runs at collection time) partially defeats this. If a full-suite run hangs while printing a failing diff, that line is the suspect.

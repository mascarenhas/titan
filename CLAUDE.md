# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Titan is a statically-typed, ahead-of-time-compiled sister language to Lua. This repo is the prototype compiler, written in Lua, that translates `.titan` modules to C and invokes the system C compiler — producing either a shared library per module (loadable from Lua via `require` and from Titan via `import`) or, when exactly one requested module defines `main(args: {string}): integer`, a standalone executable bundling all modules. The language reference is `doc/language/index.md`; the implementation documentation (lexer/parser, checker, code generator, interop machinery) is `doc/implementation/index.md`.

## Prerequisites (important — the suite cannot run without these)

- **Lua 5.5.** Both the compiler's own Lua code and the generated C target Lua 5.5 (rockspec: `lua ~> 5.5`). CI (`.github/workflows/ci.yml`) uses hererocks (installed from git master — the PyPI release does not know Lua 5.5) to build a Lua 5.5 + LuaRocks environment.
- **A built Lua 5.5.0 source tree at `./lua-5.5.0`** (gitignored). Generated C includes Lua *internal* headers (`lobject.h`, `lgc.h`, `lvm.h`, ...) and links `lua-5.5.0/src/liblua.a`. Easiest: `make lua` (downloads the tarball, extracts, builds with `MYCFLAGS=-fPIC`, auto-picking the `linux`/`macosx` target from `uname`; override with `make lua LUA_PLATFORM=...`). By hand:
  ```
  wget http://www.lua.org/ftp/lua-5.5.0.tar.gz && tar zxvf lua-5.5.0.tar.gz
  cd lua-5.5.0 && make linux MYCFLAGS=-fPIC    # 'make macosx' on Darwin
  ```
- **Lua deps**: `luarocks make titan-dev-1.rockspec` installs lpeglabel, inspect, argparse, luafilesystem, plus the `titan` runtime-support module (`titan.backtrace()`) that one coder spec requires. The rockspec is format 3.0 and declares `test_dependencies` (busted, cluacov) plus a `test = { type = "busted" }` block, so `luarocks test` installs those and runs the suite (no separate `luarocks install busted`). Note `luarocks test` does **not** build the rock-under-test — only its deps — so the `titan` C module won't exist on a fresh tree until you `luarocks make`; `make test` runs both for you.
- **C toolchain**: `cc` for compilation; the C FFI also shells out to `gcc -dM -E` and `cpp -v` at compile time (POSIX only).

## Commands

```sh
make lua                                            # download + build the ./lua-5.5.0 source tree (one-time setup)
make test                                           # `luarocks make` + `luarocks test`: (re)install the rock, then run the full suite
luarocks make && luarocks test -- -c -o gtest -v    # what CI runs (luarocks test does NOT build the rock; flags after -- go to busted; -c = coverage)
make clean                                           # remove generated artifacts; `make distclean` also removes the lua tree

busted                                              # full test suite — MUST run from repo root (all driver paths are relative); busted recurses into spec/ subdirs
busted spec/parser_spec.lua                         # single spec file
busted spec/coder/coder_spec.lua --filter='for loop' # single test (Lua pattern on test name)
LUA_CPATH="./?.so;$HOME/.luarocks/lib/lua/5.5/?.so;;" busted   # if the 'titan' rock lives in a local rocks tree

./titanc [--print-ast] [-v] [--lua <luasrc>] [--tree <srcroot>] [-l lib1,lib2] <module>...
```

**Spec layout.** Pure, layer-level specs live at `spec/` root (`cpp_spec`, `lexer_spec`, `location_spec`, `parser_spec`, `symtab_spec`, `types_spec`, `util_spec`). Checker-only specs (run the checker, never generate or execute code) live under `spec/checker/` (`checker_spec`, `first_class_functions_spec`, `so_rehydration_spec`); end-to-end specs (generate C, compile, run) under `spec/coder/` (`coder_spec`, `first_class_functions_spec`, `so_import_spec`). Keep the two apart — a checker assertion belongs in `spec/checker/`, anything that compiles and runs in `spec/coder/`. All driver/artifact paths inside specs are relative to the repo-root CWD (not the spec file), so subdir specs still run from repo root. The shared compile/run/import scaffolding (`parse`, `compile`, `call`, `run_coder`, `generate_modules`, `build_so_chain`, `check_against_so`, `run_checker`, `check_errs`, `DEPTH_PROBE`, ...) lives in **`spec/support/helpers.lua`**, `require`d as `spec.support.helpers`; it pulls in luassert explicitly (`require 'luassert'`) because a `require`d module does not inherit busted's `assert` global. Set `helpers.verbose = true` (was a per-file `local verbose`) to print `cc` command lines and keep generated `.c` files.

`titanc` takes dot-separated **module names**, not file paths (dots map to directory separators under `--tree`, default `.`). Compiled-module lookup uses `TITAN_PATH_0_7`/`TITAN_PATH` (default `.;/usr/local/lib/titan/0.7`). The compiled-module ABI version is `0.7` (bumped from `0.6` when record instances and module state (`_mod`) collapsed from a `CClosure`+`Udata` pair to a single Lua 5.5 `Udata` — `ctype(Type.Nominal)` and `_mod` are now `Udata*` throughout the native ABI and `<mangled>_init` returns `Udata*`; `0.6` itself was bumped from `0.5` when the native calling convention gained the `_fn` closure parameter — see the coder section); `.so`s built by an older Titan are incompatible. `-v` prints the exact `cc` command lines. Without the `lua-5.5.0` build, only the pure specs pass (cpp, lexer, location, parser, symtab, types, util); `spec/checker/` and `spec/coder/` need the full setup.

**Gotcha — the installed rock shadows the working tree under busted.** The busted launcher prepends the rocks tree to `package.path` and uses `luarocks.loader`, so once `luarocks make` has installed the `titan` rock, `require "titan-compiler.X"` inside specs resolves to the *installed snapshot*, not your edited files — edits silently don't take effect. Re-run `luarocks make --local titan-dev-1.rockspec` after changing compiler sources, before running busted. (`make test` re-runs `luarocks make` for you each time, so it always tests current sources; `luarocks test` on its own does **not** rebuild the rock.)

### Lua 5.5 internals conventions in generated C

The coder targets Lua 5.5 internals; keep these idioms when touching templates: stack fields are unions (`L->top.p`, `L->ci->func.p`, `StkId` + `s2v()` to view a slot as `TValue*`); the table array part has no `TValue` slots (read via `luaH_fastgeti`/`luaH_getint` into a local `TValue` holder testing `tagisempty(tag)`, write via `obj2arr`/`luaH_setint`/`luaH_set` — `luaO_nilobject` and `luaH_newkey` no longer exist); booleans carry no payload (`ttistrue`, `titan_setbvalue` from titan.h); `ttypetag()`/`LUA_V*` are the variant tags (old `ttnov` is now `ttype`); a record value IS a `Udata` (created with `luaS_newudata(L, sizeof(void*), N)`) — its fields live in `uv[0..N-1].uv` (0-based, no reserved `uv[0]`), the type tag is the one `void*` in `getudatamem(_ud)`, and the metatable sits on the udata's `metatable` field; `_mod` (module state) is likewise a single `Udata`. Stores of collectable values into a `CClosure` upvalue (function values; capture boxes are userdata, see below) need the **forward** `luaC_barrier(L, owner, slot)`, while record-field and module-slot stores into a `Udata` user value and table stores need the **back** `luaC_barrierback(L, obj2gco(o), v)` (genlink-safe on userdata) — the generational GC makes missing barriers near-deterministic corruption, not a rare race.

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

- Each Titan function becomes **two** C functions: a raw native-convention one (`RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, params..., out-params for returns 2..n)`; the **caller** anchors GC-able arguments on the Lua stack) and a Lua-stack entry wrapper that coerces arguments and installs the error handler. `_fn` is the function value's own closure (still a `CClosure`): `NULL` on fully-static top-level calls, and the callee itself on first-class/closure/value calls; for anonymous functions it carries the captured variables (this uniform parameter is what bumped the module ABI to `0.6`). `_mod` becoming `Udata*` and record instances becoming a single `Udata` (so every record-typed param/return changes C type and `<mangled>_init` returns `Udata*`) is what bumped it to `0.7`.
- Module state is a `Udata` (`_mod`), allocated with `luaS_newudata(L, 0, NUPVALS)`: there is no reserved user value; the module's user values (0-based) hold module globals, exported-function canonical closures, imported-module `Udata`s, record metatables, and per-record static-namespace tables. There is **no** Lua-facing module table — `require` returns the module `Udata` itself (so `type(require "m")` is `"userdata"`), and all member access (functions, variables, record namespaces `m.Rec`) flows through a metatable `__index`/`__newindex` over a unified name→slot member map; functions and record namespaces are served read-only (assigning errors), variables coerce in/out, and the "not found" message is "member '%s' does not exist". A record instance is likewise a single `Udata` (fields in `uv[0..N-1]`, tag in `getudatamem`, metatable on the udata).
- First-class function values are `CClosure`s (upvalue 0 = `_mod`, then a type tag, the native pointer, and one upvalue per captured variable); anonymous functions/closures and `obj:method` **bound methods** are supported as values. A captured-and-mutated local is stored in a **box** so all sharers mutate one cell. A box is a Lua *userdata* (not a CClosure): a userdata's GC traversal calls `genlink`, so an overwriting write can use the back barrier (`luaC_barrierback`) without floating fresh values to the old generation — which a `CClosure`/forward-barrier box would (`traverseCclosure` does not call `genlink`). Two forms, chosen by `not types.is_gc(typ)`: a 1-user-value `Udata` holding a `TValue` written with `luaC_barrierback` (GC-typed values), or a 0-user-value `Udata0` holding the raw non-GC C scalar inline via `getudatamem` (no tagging, no barrier). Boxes are module-internal (never cross a module boundary), so the representation is not part of the ABI.
- Generated C must follow the style contract in `pretty.lua`'s header (K&R braces, `/**/` comments never after `{`, braces mandatory) — `reindent_c` is purely heuristic.
- Deps with available `.titan` source are compiled in and statically linked; `.so`-only deps are dlopened at runtime by the generated `_init`. Every compiled module exports `luaopen_<mangled>`, `<mangled>_init` (idempotent), and `<mangled>_types` (serialized interface type, evaluated with `types.lua` as env).
- `titan-runtime/titan.o` is rebuilt lazily by the driver from `titan.c` (dlopen-based module loader, error handler with C backtrace). `titanlib.c` is a separate optional Lua module exposing `titan.backtrace()`.

### C FFI (`c-parser/`, `foreigntypes.lua`)

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; gets system include paths and predefined macros by shelling out to `cpp`/`gcc`), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList). `foreigntypes.convert` maps the results to checker types (`char*` → String, `T*` → ad-hoc `Type.Pointer` tables not made by typedecl); struct/union/enum field handling is still TODO. `typed.lua` (used only by c-parser) is a runtime signature-checking DSL that ships **disabled** — `typed.off()` is the last line; flip to `typed.on()` to debug c-parser type confusion.

## Test suite notes

- `spec/coder/coder_spec.lua` is end-to-end: it generates C, compiles with the real `cc`, and runs the result under `lua-5.5.0/src/lua` via `io.popen`. Artifacts (`test.c`, `test.so`, `./test`, `*.o`) land in the repo root; `after_each` cleans them. Its `setup()` deletes `titan-runtime/titan.o` to force a runtime rebuild. Set `helpers.verbose = true` in `spec/support/helpers.lua` to see `cc` command lines and keep generated `.c` files.
- The **`.so`-only import path** (a dependency reachable only as a compiled shared library, not `.titan` source) has dedicated coverage: `spec/coder/so_import_spec.lua` (end-to-end: dlopen + dlsym, cross-module function/variable/record use incl. transitive `.so`→`.so` chains, and the first-class fast path across the `.so` boundary) and `spec/checker/so_rehydration_spec.lua` (the typechecker rehydrating function/record/variable/first-class-function types from the serialized `<mangled>_types` symbol). Both build each dependency `.so` *from memory* so its `.titan` source never reaches the source path, forcing `driver.defaultloader` down the `.so` route; `build_so_chain`/`so_check` assert the dep was resolved dynamically, not statically linked. A module's interface may *reference* a record defined in a module it imported but that the importer does not import directly — `checker.checkimport` recovers those transitively-referenced record modules so their nominal types still resolve.
- `cpp_spec.lua` is the only coverage for the FFI preprocessor (`c-parser/cpp.lua`), and runs **without** the C toolchain: its `expand` helper drives `cpp.parse_file` with a hand-built `ctx` (empty `defines`/`incdirs`) so the `gcc`/`cpp` shell-out is skipped, and wraps each expansion in a Lua instruction-count `debug.sethook` so a regression that reintroduces unbounded macro recursion fails loudly instead of hanging the suite. The recursion-guard cases pin the C "no recursive expansion" rule — keep them when touching macro loop detection.
- Test helpers that touch the checker/coder must reset shared state first: `types.registry = {}` (and `driver.imported = {}` where imports are involved) — see `run_checker`/`run_coder`.
- Parser/checker specs compare ASTs with a subset assertion (`restrict` + `assert_is_subset`): only fields present in the expected table are compared, so adding new AST decorations doesn't break existing tests. Follow this pattern.
- `TableFormatLevel` (luassert's table-printing depth) is global across spec files, and post-checker ASTs are self-referential — printing one in a failure diff at unlimited depth hangs busted. `parser_spec.lua` raises the depth in `setup()` and restores it in `teardown()`, but a stray `assert:set_parameter("TableFormatLevel", -1)` in its describe body (runs at collection time) partially defeats this. If a full-suite run hangs while printing a failing diff, that line is the suspect.

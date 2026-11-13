# Target source selection

A logical source file `name.titan` may have **target variants** spelled
`name.<label>.titan`. Each compilation has one *target*, and for every logical
filename it selects exactly one file: the most specific existing variant that
applies to that target, or else the default `name.titan`. The selected file
then takes the place of the logical file everywhere: in flat modules, in
folder-module mains, and in folder contributors.

```
net/
  socket.titan           # default implementation
  socket.windows.titan   # selected on Windows
  socket.native.titan    # selected on every other native host
```

Selection only chooses files. It does not create modules, change logical module
names, or add conditional compilation inside a file. The selected files are
parsed, checked, and compiled exactly as if they had been written under the
logical name. One logical module still has one checker pass, one interface, one
initializer, and one set of generated artifacts.

Use variants for implementations that really differ between targets. Small
differences, such as a constant or a C declaration, belong in C headers and
their preprocessor conditionals behind a `foreign import`, not in whole-file
copies.

## Targets and labels

There are five source labels. Four of them name a target; `native` is an
umbrella label for every native operating-system host.

| Label | Applies to |
| --- | --- |
| `linux` | the Linux target |
| `darwin` | the macOS target |
| `windows` | the Windows target |
| `browser` | the browser target |
| `native` | every native host: Linux, macOS, Windows, and any other native operating system; never `browser` |

The default target is the host: `windows` on Windows, `darwin` when `uname`
reports `Darwin`, and `linux` when it reports `Linux`. A native host with any
other operating system, such as a BSD, has no OS label of its own. It compiles
for a native host without an OS label and selects `name.native.titan`, then
`name.titan`. Existing source trees keep building there unchanged.

`titanc` compiles for the browser target with `--target browser`, as described
in [Compiling for the browser target](browser-target.md). A native build never
selects a `.browser.titan` file, and a browser build never selects a
`.native.titan` or OS-labeled file; see
[choosing the target](#choosing-the-target--t--target-and-titan_target). The
standard library uses this for its native-only modules: `titan/fs.native.titan`
and the folder main `titan/uv/uv.native.titan`, among others, have no default,
so those modules [do not exist for the browser
target](browser-target.md#modules-that-are-not-available).

## Variant filenames

`<base>.<label>.titan` is a variant of the logical file `<base>.titan` when
`<label>` is one of the five labels and `<base>` is not empty. Exactly one
trailing label is removed. Labels are lowercase ASCII and match exactly.

| Filename | Meaning |
| --- | --- |
| `socket.linux.titan` | the `linux` variant of `socket.titan` |
| `socket.titan` | the default member of the `socket.titan` family |
| `linux.titan` | the ordinary logical file `linux.titan`: its base would be empty |
| `linux.native.titan` | the `native` variant of `linux.titan` |
| `x.y.titan` | the ordinary logical file `x.y.titan`, because `y` is not a label |
| `x.y.linux.titan` | the `linux` variant of `x.y.titan` |
| `x.linux.native.titan` | an error: stacked target labels |
| `x.Linux.titan` | an error: a mis-cased target label |

A filename and its variants form one **family**. A variant filename is never a
module name, because a module-name component cannot contain a dot.

Inside a folder module, a contributor basename that ends in `.<label>` is always
a variant. A contributor literally named `helpers.linux` cannot exist: the file
`helpers.linux.titan` is the `linux` variant of contributor `helpers.titan`.
Other dotted contributor names, such as `x.y.titan`, keep their ordinary
meaning.

Stacked and mis-cased labels are diagnosed wherever the compiler enumerates
filenames: when it sweeps a selected folder module's directory, and during
[`--test-dir` discovery](standard-library-test.md#automatic-test-root-discovery).
The diagnostics read `stacked target labels in source 'x.linux.native.titan'`
and `mis-cased target label in source 'x.Linux.titan'`. A folder sweep diagnoses
every `.titan` regular file in the directory, including files of the main's
family and files for other targets. Rename the file to one label in lowercase.

A flat lookup does not enumerate a directory. It probes the exact lowercase
spellings of the target's row, and, like module paths themselves, it inherits
the case behavior of the filesystem: on a case-insensitive filesystem the probe
for `x.linux.titan` can open a file spelled `x.Linux.titan`. Keep labels
lowercase so that every filesystem selects the same file.

## Selecting one file per family

For each logical filename `name.titan`, the compiler selects the first existing
regular file in its target's row:

| Target | Selection order |
| --- | --- |
| `windows` | `name.windows.titan`, `name.native.titan`, `name.titan` |
| `darwin` | `name.darwin.titan`, `name.native.titan`, `name.titan` |
| `linux` | `name.linux.titan`, `name.native.titan`, `name.titan` |
| native host without an OS label | `name.native.titan`, `name.titan` |
| `browser` | `name.browser.titan`, `name.titan` |

A label **applies** to a target when it appears in that target's row.

* **Target-only files.** A family needs no default file. A family with no
  applicable member is absent for that target: a module whose only files are
  `name.windows.titan` does not exist on Linux, and a folder contributor with
  no applicable member is silently left out of the composition.
* **Files for other targets are invisible.** A file whose label does not apply
  is never read, import-scanned, parsed, or searched for `foreign import`
  directives. It may contain syntax errors or name headers that do not exist on
  this host.
* **Fallback happens only on absence.** Once a file is selected, an error in it
  is an error in that module. A read, enumeration, parse, header, or type error
  never falls back to a less specific member of the family, to the other source
  form, or to a later source root.

## Precedence

Specificity applies within one family only. It does not reorder source roots or
source forms. For each source root, the compiler tries the folder form first,
then the flat form, then moves to the next root, as described in [folder
module lookup](folder-modules.md#lookup-and-precedence):

1. the family of the folder main `P/B.titan`;
2. the family of the flat source `P.titan`;
3. the next `--tree` root.

So:

* an earlier root's `foo.titan` beats a later root's `foo.linux.titan`;
* a selected folder main `foo/foo.titan` beats the flat `foo.linux.titan`
  beside the `foo/` directory;
* with only `foo/foo.browser.titan` and a flat `foo.titan`, the folder form is
  absent on native hosts, so they select the flat `foo.titan`.

A module can therefore be a folder module on one target and a flat module on
another. Its logical name and interface rules are the same either way; only its
source files and its executable name (`foo__main` for the folder form, `foo` for
the flat form) follow the selected form.

Ordinary dependency lookup still prefers compiled providers, command-line roots
and explicit `.titan` imports still require source, and `--test` and
`--source-first` still prefer source. Selection changes only which source file
represents each source form.

## Folder modules

A folder module's main family is `P/B.titan` and every `P/B.<label>.titan`. The
selected main is the first applicable member of that family. The contributors
are then composed as follows:

1. Every immediate regular `*.titan` file in the folder is listed.
2. The whole main family is removed, including members for other targets.
3. The remaining files are grouped by logical filename, and one file is selected
   from each group with the target's row. A group with no applicable member is
   dropped.
4. The selected contributors are ordered by numeric byte order of their logical
   filename, `.titan` included, with only the label removed:
   `ops.native.titan` sorts as `ops.titan`.

Declarations then follow the usual [folder order](folder-modules.md#declaration-order):
the main's declarations, the contributors in that order, and finally the main's
optional module initializer. Replacing a file by a variant never moves it in
this order, and a tree without variants keeps exactly its existing order:
`a-common.titan` sorts before `a.titan`, which sorts before `a_extra.titan`.
Replacing the main keeps every other selected contributor.

```
app/example/
  example.titan                 shared main
  operations-common.titan       ordinary shared contributor
  operations.native.titan       implementation for native hosts
  operations.browser.titan      browser implementation
  native-helpers.native.titan   left out of the browser composition
```

| Target | Files in composition order |
| --- | --- |
| native hosts | `example.titan`, `native-helpers.native.titan`, `operations-common.titan`, `operations.native.titan` |
| `browser` | `example.titan`, `operations-common.titan`, `operations.browser.titan` |

The `-common` suffix is only a convention. Adding `operations.linux.titan`
would replace `operations.native.titan` on Linux while keeping the shared
helpers in `operations-common.titan`.

### The module initializer

Only the selected main may end in the root module initializer. A selected
contributor with a root initializer is rejected with the folder-module
diagnostic, which names the selected main (`module initializer is only allowed
in the folder main source '…'`). Files for other targets are never parsed, so
their initializers do not matter.

A main variant replaces the default main completely; it does not inherit the
default main's initializer. Put shared initialization in a function in a shared
contributor and call it from each main's initializer:

```titan
-- app/clock/setup.titan (shared contributor)
local ticks: integer = 0

local function start_clock()
    ticks = 1
end
```

```titan
-- app/clock/clock.titan (default main)
function resolution(): integer
    return ticks
end

do
    start_clock()
end
```

```titan
-- app/clock/clock.windows.titan (Windows main)
function resolution(): integer
    return ticks * 10
end

do
    start_clock()
end
```

### Constituents stay private

A flat lookup for `pkg.service.worker` is blocked when its parent directory
`pkg/service/` holds any file of the main family `service.titan`, for any
label, even one that does not apply. The parent need not be present for the
current target. With `pkg/service/service.windows.titan` and
`pkg/service/worker.titan`, Linux has no `pkg.service` module, and
`pkg.service.worker` still cannot be imported from that file. A genuine deeper
folder module, `pkg/service/worker/worker.titan`, still wins before this
check, and a constituent family with no applicable file is an ordinary miss.
The [constituent rules](folder-modules.md#contributors-are-not-directly-importable)
are otherwise unchanged.

## Module identity, imports, and C headers

Variant filenames never reach module identity. The logical module name alone
names the checker scope, the interface, the module initializer, the native
symbols, the generated artifacts, and the name Lua uses with `require`.

There is no syntax for importing a particular variant and no per-import target.
`import "foo.linux.titan"` keeps its meaning as an
[explicit source import](source-import-visibility.md) of logical module
`foo.linux`, which is the file `foo/linux.titan` or `foo/linux/linux.titan`,
not the file `foo.linux.titan`. `import "pkg.service.titan"` selects the active
composition of `pkg.service` for the target, and its local visibility covers
exactly the selected files.

A module's public interface may differ between targets: each target checks
importers against the interface of its own selection.

All selected files of a module share one ordered C environment, as in any
folder module. A `foreign import` in a file for another target never enters it.
Quoted headers are resolved relative to the directory of the selected main;
variants are siblings of their default, so that directory does not change.

## Choosing the target: `-T`/`--target` and `TITAN_TARGET`

`titanc -T <label>` or `titanc --target <label>` selects the target, as a
separate argument; `--target=<label>` is accepted too. The short `-t` remains
`--tree`. Without the option, `titanc` reads the `TITAN_TARGET` environment
variable. Native compilation is available only for the host, and the browser
target only from Linux and macOS hosts:

| `-T`/`--target` or `TITAN_TARGET` | Result |
| --- | --- |
| absent or empty | the host target |
| the host's own OS label, such as `linux` on Linux | accepted; the same as absent |
| another OS label | error, for example `--target windows: native cross-compilation is not supported (host is linux)` |
| `native` | error: `--target native: 'native' selects source files for native hosts; it is not a compilation target` |
| `browser` | the [browser target](browser-target.md) on Linux and macOS hosts; on any other host, error: `browser builds are supported from Linux and macOS hosts (host is windows)` |
| anything else | error, for example `--target wasm32: unknown target 'wasm32': expected linux, darwin, windows or browser` |

On a native host without an OS label, there is no own label to accept, so every
nonempty value is an error; the cross-compilation message then reports
`(host is native)`, and so does the browser message.

* The option wins over the environment, including an explicitly empty option:
  `--target ''` selects the host and ignores `TITAN_TARGET`. An empty
  `TITAN_TARGET` also means the host.
* Environment errors name the variable, as in
  `TITAN_TARGET=wasm32: unknown target 'wasm32': ...`.
* The target is validated on every invocation before any source lookup,
  including `-c --c-source` invocations without Titan modules, and before the
  usage error for an invocation without modules. `--target browser` then also
  requires `--output` (`--target browser requires --output`).
* `titanc --print-root` ignores both the option and `TITAN_TARGET`, whatever
  their values. The run-time [SDK fallback](modules.md#the-titan-path) runs that
  query and must not depend on the caller's target settings.

Only the `titanc` command reads `TITAN_TARGET`. The compiler library and the
language server do not. Build automation that must not inherit a target from
its caller should unset the variable for its `titanc` commands.

## Generated files keep logical names

Generated files are named from the logical module, never from a selected
variant. A module whose selected file is `foo.linux.titan` produces `foo.c`,
`foo.o`, split parts `foo.part1.c` and `foo.part1.o`, `foo.priv.h`,
`foo.titan.h`, `foo.ffi.h`, coverage notes and counters, and the executable
`foo`, or `foo__main` for a folder module; no `*.linux.*` artifact appears.
This holds with and without `--output`. Without `--output`, the generated C,
objects, and headers sit beside the canonical path `P.titan` or `P/B.titan`,
whether or not a default file exists there, while the executable and provider
paths stay relative to the working directory. See [Output
directories](output-directory.md) and [compiling
modules](modules.md#compiling-modules-titanc) for the locations.

## Diagnostics, tracebacks, and coverage name the real file

Source locations always name the selected physical file. Type and syntax
diagnostics, generated `#line` directives, native tracebacks, and
[coverage reports](native-coverage.md) report `foo.linux.titan`, with its own
lines.

## Incremental builds

A certified object records the ordered list of files its module was compiled
from ([incremental compilation](incremental-compilation.md#what-object-reuse-promises)),
and every invocation selects files afresh. Therefore:

* adding or removing a variant that changes the selection rebuilds the module
  (`source-set` in `-v` output);
* switching between two byte-identical files still rebuilds it, because the
  file path is part of the generated code;
* adding a contributor variant in a folder rebuilds that module only; its
  importers follow the ordinary interface rules; and
* adding, editing, or removing a file whose label does not apply compiles and
  links nothing.

## Test roots

[`--test-dir` discovery](standard-library-test.md#automatic-test-root-discovery)
uses the same selection. `foo_test.linux.titan` is the test root `foo_test`
when its label applies to the target, and the ordinary resolver decides which
member of the family runs. Files for other targets are skipped without an
error, so a platform-only test needs no `--test-exclude`. Several variants of
one root are one root. A folder root with no applicable main is skipped like
any other directory that is not a module.

## Editors

The language server analyzes the host target only. It groups variants under
their logical module and follows the selection, composition, privacy, and
precedence rules of this chapter. A variant the host target does not select is
not analyzed and gets one information-severity diagnostic that names the
selected member, or says that the family has no active variant; the default
contributors of a folder module absent for the host are reported the same way.
Such files get no semantic completion. `TITAN_TARGET` has no effect on the
server, and there is no setting to choose another target.

See [target source selection](../implementation/target-source-selection.md) in
the implementation manual for the resolver, the driver API, and the build
integration.

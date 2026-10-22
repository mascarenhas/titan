# Lexical filesystem paths

`titan/path.titan` and `titan-compiler/path.lua` implement the same lexical
filesystem API. The language contract is in
[Filesystem paths](../language/standard-library-path.md). Neither implementation
performs I/O or canonicalizes physical identity. The compiler's filesystem
identity and Windows absolute-path helpers keep their separate contracts.

## Grammar selection

The Titan module imports only `string`. Its private `path_platform.h` defines
`TITAN_PATH_WINDOWS` from the C compiler's `_WIN32`, so the grammar follows the
compiled target. The module's root initializer sets the private `windows` flag
and the public `const separator: string?`. The declaration is optional because
computed module state is assigned in that initializer; a successful import
always leaves it non-nil.

The Lua implementation selects its grammar from the first byte of
`package.config` (`titan-compiler/path.lua`). Its spec loads the same source with
a test-local configuration to exercise both grammars without adding platform
selectors to the public API.

## Normalization and join

`normalize` scans bytes, identifies a Windows volume (`volume_length`) when
applicable, and tracks ordinary components with a stack. Relative `..` survives
when no ordinary component can be cancelled; rooted `..` stops at the root. A
rewrite flag records whether constructing any component diverged from the
input, even if that component is later cancelled. Namespace guards inspect the
surviving output so that dot removal cannot introduce a drive-relative or
device prefix. `split` deliberately bypasses normalization and preserves raw
bytes. `join` preserves Windows drive-relative and UNC boundaries while
inserting native separators, then normalizes once.

The algorithms adapt Go's BSD-licensed `internal/filepathlite` and
`path/filepath` sources; the license is `LICENSES/go-LICENSE`. Three Windows
inputs intentionally differ from Go: `/??/../../.` normalizes to the root `\`,
and `./foo:bar/..` and `./foo:bar/../` normalize to `.`. Go's mutable scratch
buffer can retain removed bytes beyond its final width and add a namespace
guard from those bytes. Titan bases the guard on surviving output, so these
results are stable under repeated normalization.

## Tests

`spec/support/path_cases.lua` is the shared fixed corpus for both grammars and
asserts the three Go differences explicitly. `spec/path_spec.lua` runs it
against the Lua helper. `spec/stdlib/titan/path/tests.titan` runs the matching
native cases against the compiled standard module on each target: root, drive,
UNC, device namespace, dot-component, separator, split and variadic-join
behavior. The module's place in the standard provider is described in
[the standard-library image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).

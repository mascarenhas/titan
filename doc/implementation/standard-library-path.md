# Lexical filesystem paths

`titan/path.titan` and `titan-compiler/path.lua` implement the same lexical
filesystem API. The language contract is in
[Filesystem paths](../language/standard-library-path.md). Neither implementation
performs I/O or canonicalizes physical identity. The compiler's existing
filesystem identity and Windows absolute-path helpers retain their separate
contracts.

The Titan module depends on `titan.string`. Its private `path_platform.h`
selects Windows grammar from the C compiler's `_WIN32` definition, so the
behavior follows the compiled target. The module initializer sets the private
platform flag and the public `const separator`; the latter has an optional
string declaration because computed module state is initialized in that root
initializer. Successful import always leaves it non-nil. Every public member
has documentation comments retained by the ordinary compiler metadata path.
No generated-code ABI or language-server API version changes are needed.

The Lua implementation selects its grammar from the first byte of
`package.config`. Its test loads the same source with a test-local configuration
to exercise both grammars without adding platform selectors to the public API.

Normalization scans bytes, identifies a Windows volume when applicable, and
tracks ordinary components with a stack. Relative `..` survives when no
ordinary component can be cancelled; rooted `..` stops at the root. A rewrite
flag records whether constructing any component diverged from the input, even
if that component is subsequently cancelled. Namespace guards inspect the
surviving output to avoid introducing a drive-relative or device prefix by dot
removal. `split` deliberately bypasses normalization and preserves raw bytes.
`join` preserves Windows drive-relative and UNC boundaries while inserting
native separators, then normalizes once.

The algorithms adapt Go's BSD-licensed `internal/filepathlite` and
`path/filepath` sources. Their license is in `LICENSES/go-LICENSE` and is staged
with the other standard-library notices. An independent official-source oracle
checked 50,322 operations during implementation. There are three intentional
Windows input differences: `/??/../../.` normalizes to the root `\`, and
`./foo:bar/..` plus `./foo:bar/../` normalize to `.`. Go's mutable scratch buffer
can retain removed bytes beyond its final width and add a namespace guard from
those bytes. Titan bases that guard on surviving output, keeping these results
stable on repeated normalization. The shared corpus asserts these differences
explicitly.

`spec/support/path_cases.lua` contains 161 fixed cases for both grammars.
`spec/path_spec.lua` exercises the Lua helper. The matching native cases in
`spec/stdlib/titan/path/tests.titan` exercise the public compiled standard
module on each target, including root, drive, UNC, device namespace,
dot-component, separator, split and variadic-join behavior. No platform cases
are omitted. The standard provider contains the module's normal ABI, types,
initializer and Lua opener entries; it is included in the ordinary module,
shim, packaging and native test inventories.

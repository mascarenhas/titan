# Filesystem paths

The `path` standard module manipulates filesystem path strings using the target
platform's rules. Import it with `import "path"` or `import "titan.path"`.
Its operations are synchronous and perform no filesystem access. They work on
byte strings and do not validate filenames, resolve symbolic links, check that
a file exists, or change the current directory.

```titan
local path = import "path"

function output_directory(source: string): string
  return path.join(path.dirname(source), "build")
end
```

On Linux and macOS, only `/` separates components; a backslash is an ordinary
filename byte. On Windows, `/` and `\` both separate components, and operations
that construct a path use `\`. Drive prefixes, UNC shares and Windows device
prefixes are recognized. Drive-relative `C:work` and rooted `\work` are not
fully qualified paths; `C:\work` and `\\server\share\work` are.

The API follows the lexical operations in Go's
[`path/filepath`](https://pkg.go.dev/path/filepath), with Titan names and typed
multiple results. It currently provides the following string operations;
filesystem traversal and physical resolution belong to `fs`.

## API

| Member | Signature | Behavior |
| --- | --- | --- |
| `separator` | `const string?` | Native separator: `/` on POSIX and `\` on Windows. Initialized before import returns, so it is always present. |
| `normalize` | `(subject: string): string` | Collapse repeated separators, remove `.`, cancel preceding ordinary components against `..`, and remove trailing separators except at a root. Empty input becomes `.`. Leading relative `..` components remain; rooted paths cannot climb above their root. |
| `join` | `(...: string): string` | Join fragments and normalize the result. Empty fragments are ignored; zero fragments or all empty fragments produce an empty string. A later rooted fragment does not discard earlier fragments. |
| `basename` | `(subject: string): string` | Last component after discarding trailing separators. Empty input becomes `.`. A root becomes the native separator. |
| `dirname` | `(subject: string): string` | Normalized directory containing the final component. Empty input or a single relative filename produces `.`. |
| `extension` | `(subject: string): string` | Suffix beginning at the last dot of the final component, or an empty string. The dot is included; `.profile` therefore has extension `.profile`. |
| `is_absolute` | `(subject: string): boolean` | Whether the path is fully qualified under the target platform's rules. |
| `split` | `(subject: string): (string, string)` | Directory prefix and final component, split after the last separator. The directory retains its separator. Original bytes are preserved: concatenating the two results always reconstructs the input. |
| `volume` | `(subject: string): string` | Windows drive, UNC/share or device volume prefix, with native separators; empty on POSIX. |
| `to_slash` | `(subject: string): string` | Replace Windows separators with `/`; unchanged on POSIX. |
| `from_slash` | `(subject: string): string` | Replace `/` with Windows separators; unchanged on POSIX. |

`split` preserves spelling while `dirname` cleans it. For example,
`split("a//b.txt")` returns `"a//", "b.txt"`, whereas `dirname("a//b.txt")`
returns `"a"`. `extension("archive.tar.gz")` returns `".gz"`.

On Windows, `join("C:", "work")` returns `"C:work"`; write a separator after
the drive when a fully qualified path is required. The leading separator in
`join("work", "/output")` simply separates the fragments. `normalize` also
keeps lexical cleanup from accidentally introducing a new drive or device
namespace: removing `a/..` from `a/../C:work` produces `".\\C:work"` on Windows.

Use lexical cleanup only when it matches the caller's intent. For example,
cancelling `link/..` does not inspect where the symbolic link points. Windows
verbatim/device filenames may have filesystem-specific semantics beyond the
module's lexical grammar.

## Compiler and Lua tests

Lua code can use `require "titan-compiler.path"`. It exposes the same names and
results, including the `separator` string, and selects its native grammar from
Lua's platform configuration. `split` returns two Lua strings and `join` takes
ordinary variadic string arguments. The compiler and its Lua test fixtures use
this helper where lexical path manipulation is appropriate.

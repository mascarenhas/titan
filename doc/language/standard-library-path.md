# Path standard library

The `path` standard module manipulates filesystem path strings lexically using
the target platform's path grammar (modeled on Go's `path/filepath`). Every
operation is synchronous, operates purely on immutable byte strings, and never
touches the filesystem or resolves symbolic links. Titan imports it with
`local path = import "path"` (parser sugar for `import "titan.path"`); Lua
loads the same module with `require "titan.path"`.

**Target availability:** Native & Browser (complete; POSIX rules on Linux,
macOS, and Browser; Windows rules on Windows). For physical filesystem
resolution and I/O, use [`titan.fs`](standard-library-fs.md).

## Example

The following module normalizes a source path, replaces its filename extension,
places the result under a build directory, and emits a portable slash-separated
manifest key:

```titan
local path = import "path"
local strings = import "string"

record ArtifactPaths
  object_file: string
  manifest_key: string
  absolute: boolean
end

function derive_artifact(source: string, out_dir: string): ArtifactPaths
  local clean = path.normalize(source)
  local dir, file = path.split(clean)
  local ext = path.extension(file)
  local stem = strings.sub(file, 1, #file - #ext)
  local obj = path.join(out_dir, dir, stem .. ".o")
  return ArtifactPaths(obj, path.to_slash(obj), path.is_absolute(clean))
end
```

## Platform path rules

- **POSIX (Linux, macOS, Browser):** Only `/` separates path components; `\` is
  an ordinary filename byte. `volume` always returns `""`, and `to_slash` /
  `from_slash` return their input unchanged. Any path starting with `/` is
  absolute.
- **Windows:** Both `/` and `\` act as separators, and path-constructing
  functions emit `\`. `volume` recognizes drive prefixes (`C:`), UNC shares
  (`\\server\share`), and device prefixes (`\\.\...`, `\\?\...`, `\??\...`).
  `is_absolute` requires both a volume and a root separator: `C:\work` and
  `\\server\share\work` are absolute, while drive-relative `C:work` and rooted
  `\work` are not.

Lexical cleanup does not inspect the filesystem: canceling `link/..` ignores
where `link` points. On Windows, `join("C:", "work")` produces `"C:work"`
(include a trailing separator on `"C:\\"` for a rooted path), and `normalize`
avoids turning relative segments into a drive prefix (`a/../C:work` becomes
`.\C:work`).

## API

```text
const separator: string?

function normalize(subject: string): string
function join(...: string): string
function split(subject: string): (string, string)
function basename(subject: string): string
function dirname(subject: string): string
function extension(subject: string): string
function is_absolute(subject: string): boolean
function volume(subject: string): string
function to_slash(subject: string): string
function from_slash(subject: string): string
```

| Member | Behavior |
| --- | --- |
| `separator` | Native path separator (`"/"` on POSIX, `"\\"` on Windows). Typed `string?` because it is set during module initialization; always non-`nil` after import and auto-unwraps wherever `string` is expected. |
| `normalize(subject)` | Collapses repeated separators, drops `.`, cancels ordinary components before `..`, and trims trailing separators except at a root. Empty input returns `"."`. Leading relative `..` components are preserved; rooted paths never climb above their root. |
| `join(...: string)` | Joins non-empty fragments with the native separator and normalizes the result. Zero or all-empty fragments return `""`. A later rooted fragment does not discard earlier fragments. |
| `split(subject)` | Splits immediately after the final separator into `(dir, file)`, keeping original bytes intact (`dir .. file == subject`). |
| `basename(subject)` | Returns the final component after trimming trailing separators. Empty input returns `"."`; a root returns the native separator. |
| `dirname(subject)` | Returns the normalized directory containing the final component. Empty input or a bare filename returns `"."`. |
| `extension(subject)` | Returns the suffix starting at the last `.` in the final component, or `""` if none. The dot is included (`".profile"` returns `".profile"`, `"archive.tar.gz"` returns `".gz"`). |
| `is_absolute(subject)` | Reports whether `subject` is fully qualified under the target platform's rules. |
| `volume(subject)` | Returns the Windows drive, UNC share, or device prefix (normalized to native separators); always `""` on POSIX. |
| `to_slash(subject)` | Replaces `\` with `/` on Windows; unchanged on POSIX. Does not normalize. |
| `from_slash(subject)` | Replaces `/` with `\` on Windows; unchanged on POSIX. Does not normalize. |

### Lexical comparison (POSIX vs. Windows)

| Expression | POSIX result | Windows result |
| --- | --- | --- |
| `path.normalize("a//b/../c/")` | `"a/c"` | `"a\\c"` |
| `path.join("work", "/out", "app.o")` | `"work/out/app.o"` | `"work\\out\\app.o"` |
| `path.split("a//b.txt")` | `"a//"`, `"b.txt"` | `"a//"`, `"b.txt"` |
| `path.dirname("a//b.txt")` | `"a"` | `"a"` |
| `path.basename("/var/log/")` | `"log"` | `"log"` |
| `path.extension("archive.tar.gz")` | `".gz"` | `".gz"` |
| `path.volume("C:/src/app.titan")` | `""` | `"C:"` |
| `path.is_absolute("/usr/bin")` | `true` | `false` |
| `path.is_absolute("C:\\work")` | `false` | `true` |
| `path.to_slash("a\\b\\c")` | `"a\\b\\c"` | `"a/b/c"` |
| `path.from_slash("a/b/c")` | `"a/b/c"` | `"a\\b\\c"` |

The following module converts between portable slash-delimited configuration
paths and native platform paths:

```titan
local path = import "path"

function native_config_path(root: string, portable_rel: string): string
  local native_rel = path.from_slash(portable_rel)
  local combined = path.join(root, native_rel)
  if path.volume(combined) ~= "" then
    return combined
  end
  return path.normalize(combined)
end

function split_components(target: string): (string, string, string)
  local sep = path.separator
  local dir = path.dirname(target)
  local base = path.basename(target)
  return sep, dir, base
end
```

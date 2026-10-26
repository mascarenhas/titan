# Third-party notices

## Experimental Windows builds

`Makefile.win` packages the pinned Lua, libuv, llhttp, and SQLite providers
as application-private DLLs. OpenSSL defaults to an installed binary SDK;
`OPENSSL_MODE=bundled` builds the pinned OpenSSL 3.5.7 source instead. The
corresponding attribution and
license texts below also accompany those DLLs. Windows does not link GNU
Readline. The private namespaced LPegLabel payload remains statically embedded
in the Titan standard provider. Compiler-only LuaFileSystem, luv, LPegLabel/relabel,
argparse, and inspect are installed as ordinary LuaRocks dependencies under
their upstream license terms. The standard-provider notices and texts are under
`share/titan/THIRD_PARTY_NOTICES.md` and `share/titan/LICENSES/`.

## libuv

Titan's standard-library binary artifacts may statically incorporate libuv
1.53.0, obtained from <https://dist.libuv.org/dist/v1.53.0/>. Libuv is
distributed under the MIT license; its unmodified license text is distributed
as `LICENSES/libuv-LICENSE` (or in the installer's corresponding license
directory).

Parts originating from Joyent and other Node contributors retain the MIT
notice reproduced verbatim in `LICENSES/libuv-LICENSE-extra`. That upstream
notice also identifies the externally maintained components: `include/uv/tree.h`,
Copyright 2002 Niels Provos, under the BSD two-clause license reproduced in
`LICENSES/libuv-tree-LICENSE`; and the `inet_pton`/`inet_ntop` implementations in
`src/inet.c`, Copyright 2004 Internet Systems Consortium, Inc. and
1996-1999 Internet Software Consortium, under the ISC license reproduced in
`LICENSES/libuv-inet-LICENSE`.

Distributions containing Titan's bundled libuv libraries must include all four
license texts and this attribution.

## luv

The compiler installs luv `1.52.1-0` on every platform, obtained from
<https://github.com/luvit/luv/releases/tag/1.52.1-0>. Luv is Copyright 2014
The Luvit Authors and is distributed under the Apache License 2.0, included in
the dependency's `LICENSE.txt`. Its bundled libuv 1.52.1 retains the same
libuv, Joyent, Niels Provos, and ISC license texts listed above.

## libbacktrace

Titan links Ian Lance Taylor's libbacktrace for native source attribution.
The Windows build uses revision `0b9b49cf4a2c9229fc052d6716e1528b2f23e91a`
from <https://github.com/ianlancetaylor/libbacktrace>, with a local PE/COFF
correction for relocated symbol addresses and bounded symbol lookup. It
disables DLL notifications and refreshes snapshots through Titan's existing
provider-load invalidation instead. The BSD license is reproduced in
`LICENSES/libbacktrace-LICENSE`.

## LLVM libunwind

Windows Titan providers and launchers statically link the CLANG64 toolchain's
LLVM libunwind. The validated toolchain uses LLVM 22.1.8, obtained from
<https://github.com/llvm/llvm-project/tree/llvmorg-22.1.8/libunwind>. It is
distributed under the Apache License 2.0 with LLVM exceptions, reproduced in
`LICENSES/llvm-LICENSE`. Distributions must include the license corresponding
to their selected toolchain.

## OpenSSL

Titan's `titan.ssl` standard module may statically incorporate OpenSSL 3.5.7,
obtained from
<https://github.com/openssl/openssl/releases/tag/openssl-3.5.7>. OpenSSL is
distributed under the Apache License 2.0; its unmodified license text is
distributed as `LICENSES/openssl-LICENSE` (or in the installer's corresponding
license directory).

Distributions containing Titan's bundled OpenSSL standard library must include
that license text and this attribution. Builds configured with
`OPENSSL_MODE=system` dynamically use the separately installed OpenSSL instead.
The Windows SDK stages that provider's matching DLLs, import libraries, and
headers for deployment.

## llhttp

Titan's `titan.http` standard module statically incorporates the generated C
parser from llhttp 9.4.3, obtained from
<https://github.com/nodejs/llhttp/releases/tag/release%2Fv9.4.3>. llhttp is
Copyright Fedor Indutny, 2018, and is distributed under the MIT license
reproduced in `LICENSES/llhttp-LICENSE`.

## SQLite

Titan's `titan.sqlite3` standard module statically incorporates SQLite 3.53.4,
obtained from <https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz>.
The official amalgamation and its matching header are in the public domain.
The source's author disclaimer and blessing are reproduced in
`LICENSES/sqlite3-LICENSE`. See <https://sqlite.org/copyright.html>.

The private archive is built with `SQLITE_THREADSAFE=1` and is incorporated
into both standard-provider configurations; it is not installed as a separate
SQLite library or header.

## lpeg_patterns URI grammar

Titan's `titan.url` URI grammar is derived from lpeg_patterns commit
`0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`, obtained from
<https://github.com/daurnimator/lpeg_patterns>. lpeg_patterns is
Copyright (c) 2012-2016 Daurnimator and is distributed under the MIT license
reproduced in `LICENSES/lpeg-patterns-LICENSE`.

## LPegLabel and LPeg

Titan's `titan.peg` standard module statically incorporates a private,
namespaced copy of LPegLabel release `v1.6.2-1`, commit
`912b0b9e8641074408ffc2259e069b188e0c717b`, obtained from
<https://github.com/sqmedeiros/lpeglabel>. LPegLabel is Copyright (c)
2014-2022 Sérgio Medeiros and is distributed under the MIT license reproduced
in `LICENSES/lpeglabel-LICENSE`.

The incorporated LPegLabel C engine is derived from LPeg and retains its
upstream source notices: Copyright (c) 2007-2019 Lua.org, PUC-Rio. The
corresponding MIT terms are reproduced in `LICENSES/lpeg-LICENSE`.

Titan's relabel interface is a reviewed Titan translation of the `relabel.lua`
shipped at that same pinned LPegLabel commit. It is distributed under the
LPegLabel terms above.

## ta-regex

Titan's regular-expression parser is a reviewed Titan translation of
`pegex.lua` from ta-regex master commit
`857e48682791ba55c98a7dd99c5fc7d71c02597d`, obtained from
<https://github.com/jugglerchris/ta-regex>. Ta-regex is Copyright (c) 2014
Chris Emerson and is distributed under the MIT license reproduced in
`LICENSES/ta-regex-LICENSE`.

The regex-to-PEG continuation construction follows the algorithm in
Marcelo Oikawa, Roberto Ierusalimschy, and Ana Lucia de Moura,
"Converting regexes to Parsing Expression Grammars", PUC-Rio, 2010,
<https://www.inf.puc-rio.br/~roberto/docs/ry10-01.pdf>.

## Lua

The format and pack/unpack parsers and semantics in `titan.string` are
translated and adapted from `lstrlib.c` in Lua 5.5.1. Lua is Copyright (C)
1994-2026 Lua.org, PUC-Rio, and is distributed under the MIT license
reproduced in `LICENSES/lua-LICENSE`.

## Go path algorithms

`titan.path` and `titan-compiler.path` adapt lexical path algorithms from
Go's `path/filepath` and `internal/filepathlite` packages, obtained from
<https://go.dev/src/internal/filepathlite/>. Those sources are Copyright
The Go Authors and distributed under the BSD license reproduced in
`LICENSES/go-LICENSE`.

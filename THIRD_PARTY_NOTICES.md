# Third-party notices

## Experimental Windows builds

`Makefile.windows` packages the pinned Lua, libuv, OpenSSL, llhttp, and SQLite
providers as application-private DLLs. The corresponding attribution and
license texts below also accompany those DLLs. Windows does not link GNU
Readline. The private namespaced LPegLabel payload remains statically embedded
in the Titan standard provider. Compiler-only LuaFileSystem, LPegLabel/relabel,
argparse, and inspect have their upstream notices installed separately under
`share/titan/0.6/licenses/`; the standard-provider notices and texts are under
`share/titan/THIRD_PARTY_NOTICES.md` and `share/titan/LICENSES/`.

## GNU Readline

Lua's interactive `linux-readline` and `macosx` targets link the prefix-local
Lua interpreter through the Readline API. When the host probe succeeds, they
use the separately installed compatible system provider, whose own license
terms apply. Otherwise, the bundled mode downloads GNU Readline 8.3 from
<https://ftp.gnu.org/gnu/readline/>, applies the exact vendored combination of
official patches 001-003, and statically links the resulting private archive
into that interpreter.

GNU Readline is Copyright (C) 1987-2025 Free Software Foundation, Inc. and is
distributed under the GNU General Public License, version 3 or later. The exact
license text from the audited Readline 8.3 source is checked in as
`LICENSES/readline-LICENSE`. A bundled installation also copies it to
`readline-build/.titan-readline-8.3-p3/share/licenses/COPYING`.

Anyone distributing a Lua interpreter through the bundled mode, or through a
system mode that selected GNU Readline, must satisfy the applicable GNU
Readline license and corresponding-source requirements. A different compatible
system provider remains governed by that provider's terms. Neither mode
incorporates the provider into Titan's compiler or standard-library artifacts.

## libuv

Titan's standard-library binary artifacts may statically incorporate libuv
1.52.1, obtained from <https://dist.libuv.org/dist/v1.52.1/>. Libuv is
distributed under the MIT license; its unmodified license text is distributed
as `LICENSES/libuv-LICENSE` (or in the installer's corresponding license
directory).

Distributions containing Titan's statically linked libuv standard library must
include that license text and this attribution.

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

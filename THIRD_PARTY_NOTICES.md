# Third-party notices

## libuv

Titan's standard-library binary artifacts may statically incorporate libuv
1.52.1, obtained from <https://dist.libuv.org/dist/v1.52.1/>. Libuv is
distributed under the MIT license; its unmodified license text is distributed
as `LICENSES/libuv-LICENSE` (or in the installer's corresponding license
directory).

Distributions containing Titan's statically linked libuv standard library must
include that license text and this attribution.

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
translated and adapted from `lstrlib.c` in Lua 5.5.0. Lua is Copyright (C)
1994-2025 Lua.org, PUC-Rio, and is distributed under the MIT license
reproduced in `LICENSES/lua-LICENSE`.

# Vendored LPegLabel

This directory contains the native and test inputs needed for Titan's private
LPegLabel engine.

- Upstream: <https://github.com/sqmedeiros/lpeglabel>
- Release: `v1.6.2-1`
- Commit: `912b0b9e8641074408ffc2259e069b188e0c717b`
- Commit date: `2023-05-02T14:22:18-03:00`
- Rockspec: <https://luarocks.org/lpeglabel-1.6.2-1.rockspec>
- Release archive: <https://github.com/sqmedeiros/lpeglabel/archive/v1.6.2-1.tar.gz>
- Release archive SHA-256:
  `5511d2704de4580c5b79b100c2daec5e773db58be9c2239e49ea2d9da2decf67`

## Imported upstream files

Production sources and headers:

```text
lplcap.c
lplcap.h
lplcode.c
lplcode.h
lplprint.c
lplprint.h
lpltree.c
lpltree.h
lpltypes.h
lplvm.c
lplvm.h
```

Test-only files:

```text
relabel.lua
test.lua
testlabel.lua
testrelabelparser.lua
```

`LICENSE` is the upstream LPegLabel license. The five C files retain the LPeg
copyright headers from which they derive.

## Local files and patches

- `titan_lpeglabel_namespace.h` maps every non-static upstream definition,
  including the `LPEG_DEBUG` printers, into the `titan_lpeglabel_*` namespace.
  The public upstream opener is renamed to the private
  `titan_lpeglabel_open`.
- `lpltypes.h` includes that namespace header and replaces the two registry
  strings with revisioned Titan-private keys. Those are the only edits to an
  imported upstream file.
- `titan_lpeglabel.h` declares the hidden private opener used by Titan's
  standard-library wrapper and the test-only host.

No object-level rewriting or linker aliasing is used.

## Imported-file SHA-256

```text
c542bd8ccb7cc0c1490ebac5d689dd307a94116c0b5e54b0b725b4eec482ae8d  lplcap.c
1114fe329cc34c7054938035e73e6bf25802e3b0b88e0f17ebe592587d405013  lplcap.h
e7540bad3759226f4dbaa14ab43e074e96082479da8c22ef21967c55cbc9f82c  lplcode.c
84dfbddbd78d4a0f6861dd8be065d5fd1c4c4aac8cd77cea3af4ad286d9be9ac  lplcode.h
f2aa188da1c2cafa362d3b8ad3c87ef4a6caef7bbbb406a86f6d5454222b16a8  lplprint.c
1b70e48cc3f8f1a57a3485f5125bda90f230b1c24e06e18adbf4e3c753af992e  lplprint.h
6f59045f7b2dde3fce865d2df4a5eef28a58a56d9a504094789883cc9fcfc918  lpltree.c
e92d8d4676a7757a028052d0e05056575b3821ba577a63231f37902c0dd180eb  lpltree.h
35bd82b8c5703ddeead2b0d0ee72975df3e7e74aebf49719f79e4c02118cb653  lpltypes.h
821db82bfa0b21993ca932fd97b4f0982641bb00e58dfbdc788656c2098e3d98  lplvm.c
6eafc02d33ff9d11abf77b8eb49b086ed684d4394c7303972d46dda7f81c2fe7  lplvm.h
615f232d2cc5d147e5c7cc0f62592619b4d4002cef99bfdc0cf170fc85a4fb89  relabel.lua
d23a0c706252ec709a566acfd0a1a758eefa1a75289bfe715e62500a06751eda  test.lua
61204e37689e7f7067c14b9a0718805926a5008c58d2fd6cad12b959a3f2885e  testlabel.lua
b10cf150bfef74dd180e1112c54a71d4c427d4c695b643fdb2404870019d7a78  testrelabelparser.lua
b57029e58122ab2f6051fc34b992fba68cb18f430809948a3e015f6ae7de9f2a  LICENSE
```

The listed `lpltypes.h` digest is the pristine upstream digest, before the
documented namespace include and registry-key edits.

## Verification

From the Titan repository root, with its standalone Lua 5.5 prefix active:

```sh
make lpeglabel
busted spec/lpeglabel_build_spec.lua
```

The spec verifies the five-member archive, configuration invalidation,
symbol namespace, hidden opener, and all three upstream suites in fresh
processes.

# Titan Lua source

`lua-5.5.1` is a Git submodule of
[mascarenhas/lua-5.5.1](https://github.com/mascarenhas/lua-5.5.1). Titan's gitlink
pins the exact source commit for every platform. Initialize it after cloning:

```sh
git submodule update --init --recursive
```

`make lua` compiles those sources directly. The Windows build copies the source
files unchanged into its separate build tree. Neither build downloads, patches,
or rewrites Lua sources. Both install the same source/header bytes in the SDK;
`PREFIX` affects native build inputs and installation only.

The fork's source changes are limited to executable-relative module paths, Titan
provider paths, Windows DLL export/import annotations, and small build hooks
for the Windows import library and interpreter resource. Both native-library
loaders retain upstream behavior and normal operating-system dependency lookup.
The Windows DLL keeps the standard name `lua55.dll`.

Changes to Lua source or provider-path versions belong in the fork. Update the
submodule gitlink after validating the new source commit. Keep Unix and Windows
objects in separate build trees. `clean-lua` removes build outputs and stamps;
it preserves the tracked submodule sources.

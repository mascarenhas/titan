#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
build=$1
prefix=$(cd "$2" && pwd)
version=3.13.0
archive="$build/luarocks-$version-windows-64.zip"
mkdir -p "$build" "$prefix/etc/luarocks"
if [[ ! -f $archive ]]; then
  curl -fL "https://luarocks.github.io/luarocks/releases/luarocks-$version-windows-64.zip" -o "$archive"
fi
unzip -o "$archive" -d "$build"
export TITAN_LUA_PREFIX=$(cygpath -m "$prefix") MSYS2_ARG_CONV_EXCL='*'
"$prefix/bin/lua.exe" -E - <<'LUA'
local prefix = assert(os.getenv('TITAN_LUA_PREFIX'))
local file = assert(io.open(prefix .. '/etc/luarocks/config-5.5.lua', 'w'))
local function setting(name, value)
  assert(file:write(name, ' = ', string.format('%q', value), ',\n'))
end
assert(file:write('lua_version = "5.5"\nfs_use_modules = true\nrocks_trees = { ', string.format('%q', prefix), ' }\n'))
assert(file:write('variables = {\n'))
for name, value in pairs {
  LUA = prefix .. '/bin/lua.exe', LUA_DIR = prefix,
  LUA_BINDIR = prefix .. '/bin', LUA_INCDIR = prefix .. '/include',
  LUA_LIBDIR = prefix .. '/lib', LUALIB = 'liblua55.a',
  CC = os.getenv('CC') or 'clang.exe', LD = os.getenv('CC') or 'clang.exe',
  AR = os.getenv('AR') or 'llvm-ar', RANLIB = os.getenv('RANLIB') or 'llvm-ranlib',
  MAKE = os.getenv('ROCK_MAKE') or 'make',
  CFLAGS = os.getenv('COMPILER_DEPS_CFLAGS') or '-O2',
  LDFLAGS = os.getenv('COMPILER_DEPS_LDFLAGS') or '',
  LIBFLAG = '-shared',
} do setting('  ' .. name, value) end
assert(file:write('}\n'))
assert(file:close())
LUA
cp "$build/luarocks-$version-windows-64/luarocks-admin.exe" "$prefix/bin/luarocks-admin.exe"
cp "$build/luarocks-$version-windows-64/luarocks.exe" "$prefix/bin/luarocks.exe"
echo 'Installed standalone LuaRocks and configured the Lua SDK as its rock tree.'
printf 'For standalone commands, export LUAROCKS_CONFIG=%q\n' "$(cygpath -m "$prefix/etc/luarocks/config-5.5.lua")"

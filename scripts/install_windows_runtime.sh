#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): install_windows_runtime.sh BUILD_ROOT LUA_SDK' >&2
  exit 2
fi
work=$(cd "$1/runtime" && pwd)
prefix=$(cd "$2" && pwd)
[[ $(cat "$work/.titan-runtime-owner") == titan-windows-runtime-v1 ]]
[[ -f $work/configuration && -f $prefix/etc/titan/lua-5.5.1-windows.config ]]
destination="$prefix/lib/titan/0.6"
mkdir -p "$destination" "$prefix/include/titan"
validate_support() {
  local native_path
  native_path=$(cygpath -m "$1")
  TITAN_SUPPORT_IMAGE="$native_path" "$prefix/bin/lua.exe" -E -e '
    local image=assert(os.getenv("TITAN_SUPPORT_IMAGE"))
    local open=assert(package.loadlib(image,"luaopen_titan"))
    local support=assert(open())
    for _, name in ipairs {"_loadlib","_loadlibglobal","_abivalue",
      "_win_tmpname","_win_reserve_sibling","_win_replace","_win_stat",
      "_win_realpath","_win_abspath","_win_resolve_executable"} do
      assert(type(support[name])=="function", "missing Windows support helper "..name)
    end
  '
}
# A full canonical provider must never be replaced with a smaller bootstrap.
# Validation is a separate process that exits before any publication operation.
if [[ -e $destination/titan.dll || -L $destination/titan.dll ]]; then
  [[ -f $destination/titan.dll && ! -L $destination/titan.dll ]]
  validate_support "$destination/titan.dll"
else
  validate_support "$work/titan.dll"
  temporary=$(mktemp "$destination/.titan-bootstrap.XXXXXX.dll")
  trap 'rm -f "$temporary"' EXIT
  cp "$work/titan.dll" "$temporary"
  if [[ -e $destination/titan.dll || -L $destination/titan.dll ]]; then
    validate_support "$destination/titan.dll"
  else
    mv "$temporary" "$destination/titan.dll"
  fi
fi
copy_changed() {
  [[ ! -L $2 ]]
  if ! cmp -s "$1" "$2"; then install -m 0644 "$1" "$2"; fi
}
copy_changed "$work/libtitan.a" "$destination/libtitan.a"
copy_changed titan-runtime/titan.h "$prefix/include/titan.h"
copy_changed titan-runtime/minicoro.h "$prefix/include/minicoro.h"
copy_changed titan-runtime/titan/ffi.h "$prefix/include/titan/ffi.h"
copy_changed "$work/configuration" "$prefix/etc/titan/runtime-windows.config"
mkdir -p "$prefix/share/titan/LICENSES"
copy_changed LICENSE "$prefix/share/titan/LICENSE"
copy_changed THIRD_PARTY_NOTICES.md "$prefix/share/titan/THIRD_PARTY_NOTICES.md"
for license in libuv lpeglabel lpeg lpeg-patterns ta-regex lua llhttp sqlite3 openssl; do
  copy_changed "LICENSES/$license-LICENSE" "$prefix/share/titan/LICENSES/$license-LICENSE"
done
echo 'Staged Windows runtime SDK and preserved the canonical support/provider image.'

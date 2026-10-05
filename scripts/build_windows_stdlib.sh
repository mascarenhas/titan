#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_stdlib.sh BUILD_ROOT SDK_PREFIX' >&2
  exit 2
fi
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
perl scripts/windows_compiler_receipt.pl check "$prefix"
source_root=$(pwd)
[[ -f titan/coroutine.titan && -f titan/json/json.titan ]]
[[ -f $prefix/bin/titanc.exe && -f $prefix/bin/lua55.dll &&
   -f $prefix/etc/titan/lua-5.5.1-windows.config &&
   -f $build_root/runtime/ltitanlib.o && -f $build_root/runtime/libtitan-lpeglabel.a ]]
modules=(coroutine uv async timer io fs net ssl url http websocket os peg string math lua iteration gc test reflect sqlite3 json)
roots=()
for module in "${modules[@]}"; do roots+=("titan.$module"); done
winprefix=$(cygpath -m "$prefix")
winsource=$(cygpath -m "$source_root")
winbuild=$(cygpath -m "$build_root")
export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS=1
export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\" -I\"$winsource/vendor/lpeglabel\""
for library in libuv libllhttp libsqlite3 libssl libcrypto; do
  [[ -f $prefix/lib/$library.dll.a ]]
  TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} \"$winprefix/lib/$library.dll.a\""
done
# The private UV address helper calls the Windows byte-order API directly.
# This import belongs to the provider, not to ordinary compiled Titan clients.
TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} -lws2_32"
export TITAN_EXTRA_LDFLAGS
# These are native argv/paths. In particular, import archives are final linker
# arguments; they must not be scanned as Titan static providers or -X payload.
export MSYS2_ARG_CONV_EXCL='*'
"$prefix/bin/titanc.exe" --source-first -j 1 --tree "$winsource" \
  "${roots[@]}" -X "$winbuild/runtime/ltitanlib.o" "$winbuild/runtime/libtitan-lpeglabel.a"
[[ -f titan.dll ]]
for module in "${modules[@]}"; do [[ -f titan/$module.lua ]]; done
echo 'Built the Windows standard-library DLL and 22 generated shims.'

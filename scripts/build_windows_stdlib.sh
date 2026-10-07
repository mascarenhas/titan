#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
if [[ $# -lt 3 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_stdlib.sh BUILD_ROOT SDK_PREFIX ROOT...' >&2
  exit 2
fi
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
source_root=$(pwd)
roots=("${@:3}")
winprefix=$(cygpath -m "$prefix")
winsource=$(cygpath -m "$source_root")
winbuild=$(cygpath -m "$build_root")
export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS="${TITAN_JOBS:-1}"
export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\" -I\"$winsource/vendor/lpeglabel\""
for library in libuv libllhttp libsqlite3 libssl libcrypto; do
  TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} \"$winprefix/lib/$library.dll.a\""
done
# The private UV address helper calls the Windows byte-order API directly.
# This import belongs to the provider, not to ordinary compiled Titan clients.
TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} -lws2_32"
export TITAN_EXTRA_LDFLAGS
# These are native argv/paths. In particular, import archives are final linker
# arguments; they must not be scanned as Titan static providers or -X payload.
export MSYS2_ARG_CONV_EXCL='*'
lua=${ROCK_LUA:-$prefix/bin/lua.exe}
titanc=${ROCK_TITANC:-$prefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc}
"$lua" "$titanc" --source-first -j "$TITAN_JOBS" --tree "$winsource" \
  "${roots[@]}" -X "$winbuild/runtime/ltitanlib.o" "$winbuild/runtime/libtitan-lpeglabel.a"
echo "Built the Windows standard-library DLL and ${#roots[@]} generated shims."

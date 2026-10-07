#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
if [[ $# != 3 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_libbacktrace.sh SOURCE BUILD_DIR PREFIX' >&2
  exit 2
fi
source=$(cd "$1" && pwd)
mkdir -p "$2" "$3"
work=$(cd "$2" && pwd)
prefix=$(cd "$3" && pwd)
: "${CC:=clang}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}" "${MAKE:=make}"
titan_windows_default_flags LIBBT_CFLAGS '-O2 -g' '-O0 -fno-lto -g'
titan_windows_default_flags LIBBT_LDFLAGS '' '-O0 -fno-lto'
: "${LIBBT_CPPFLAGS:=}"
# Upstream configure owns feature detection. Its generated Makefile owns the
# ordinary source graph; clean this directory when tools/profile/flags change.
if [[ ! -f $work/Makefile ]]; then
  (cd "$work"
    "$source/configure" --srcdir="$(cygpath -m "$source")" \
      --disable-shared --enable-static \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="$LIBBT_CFLAGS" CPPFLAGS="$LIBBT_CPPFLAGS" \
      LDFLAGS="$LIBBT_LDFLAGS -static-libgcc")
fi
# Native GNU Make needs native paths and a shell executable on PATH. MSYS
# Bash still runs upstream libtool/configuration recipes with native Clang.
"$MAKE" -C "$(cygpath -m "$work")" -j1 SHELL=bash.exe
mkdir -p "$prefix/lib" "$prefix/include"
install -p -m 0644 "$work/.libs/libbacktrace.a" "$prefix/lib/libbacktrace.a"
install -p -m 0644 "$source/backtrace.h" "$work/backtrace-supported.h" "$prefix/include/"

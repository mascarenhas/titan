#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
if [[ $# != 3 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_libbacktrace.sh SOURCE BUILD_DIR PREFIX' >&2
  exit 2
fi
source=$(cd "$1" && pwd -P)
mkdir -p "$2" "$3"
work=$(cd "$2" && pwd -P)
prefix=$(cd "$3" && pwd)
: "${CC:=clang}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}" "${MAKE:=make}"
titan_windows_default_flags LIBBT_CFLAGS '-O2 -g' '-O0 -fno-lto -g'
titan_windows_default_flags LIBBT_LDFLAGS '' '-O0 -fno-lto'
: "${LIBBT_CPPFLAGS:=}"
allocator_source_digest() {
  perl -I "$(dirname "$0")" -MWindowsLibbacktraceAllocator \
    -e 'print WindowsLibbacktraceAllocator::build_digest($ARGV[0])' "$source"
}
allocator_digest=$(allocator_source_digest)
allocator_receipt="$work/.titan-libbacktrace-allocator-build"
if [[ -e $allocator_receipt || -L $allocator_receipt ]]; then
  [[ -f $allocator_receipt && ! -L $allocator_receipt ]] || {
    echo 'ordinary libbacktrace allocator build receipt required' >&2; exit 1;
  }
fi
previous_allocator_digest=
if [[ -f $allocator_receipt ]]; then previous_allocator_digest=$(cat "$allocator_receipt"); fi
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
check_configured_source() {
  local configured_source
  configured_source=$(perl -I "$(dirname "$0")" -MWindowsLibbacktraceAllocator \
    -e 'print WindowsLibbacktraceAllocator::configured_source($ARGV[0])' "$work/Makefile") || {
    echo 'Cannot verify libbacktrace configured source; clean the private build directory.' >&2; return 1;
  }
  configured_source=$(cygpath -u "$configured_source") || {
    echo 'Cannot convert libbacktrace configured source; clean the private build directory.' >&2; return 1;
  }
  configured_source=$(cd "$work" && cd "$configured_source" && pwd -P) || {
    echo 'Cannot resolve libbacktrace configured source; clean the private build directory.' >&2; return 1;
  }
  [[ $configured_source == "$source" || $configured_source -ef "$source" ]] || {
    echo 'Libbacktrace build directory is configured for another source; clean the private build directory.' >&2; return 1;
  }
}
check_configured_source
# Source preparation may upgrade an already completed acquisition. A content
# receipt also catches a restored/coarse source mtime. Preserve unrelated
# objects and configuration, and keep the previous receipt on build failure.
if [[ $previous_allocator_digest != "$allocator_digest" ]]; then
  rm -f "$work/alloc.o" "$work/alloc.lo" "$work/.libs/alloc.o" \
    "$work/.libs/libbacktrace.a" "$work/libbacktrace.la"
fi
# Native GNU Make needs native paths and a shell executable on PATH. MSYS
# Bash still runs upstream libtool/configuration recipes with native Clang.
"$MAKE" -C "$(cygpath -m "$work")" -j1 SHELL=bash.exe
[[ -f $work/.libs/libbacktrace.a && ! -L $work/.libs/libbacktrace.a ]] || {
  echo 'libbacktrace archive build produced no ordinary static archive' >&2; exit 1;
}
check_configured_source
[[ $(allocator_source_digest) == "$allocator_digest" ]] || {
  echo 'libbacktrace allocator source changed during archive build' >&2; exit 1;
}
if [[ $previous_allocator_digest != "$allocator_digest" ]]; then
  allocator_pending=$(mktemp "$work/.allocator-build.XXXXXX")
  trap 'rm -f "$allocator_pending"' EXIT
  printf '%s\n' "$allocator_digest" > "$allocator_pending"
  mv -f "$allocator_pending" "$allocator_receipt"
  trap - EXIT
fi
mkdir -p "$prefix/lib" "$prefix/include"
install -p -m 0644 "$work/.libs/libbacktrace.a" "$prefix/lib/libbacktrace.a"
install -p -m 0644 "$source/backtrace.h" "$work/backtrace-supported.h" "$prefix/include/"

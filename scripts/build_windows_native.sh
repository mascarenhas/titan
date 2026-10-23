#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_native.sh BUILD_ROOT PREFIX' >&2
  exit 2
fi
mkdir -p "$1/native" "$2"
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
sources="$build_root/native-src"
work="$build_root/native"
: "${CC:=clang}" "${CXX:=clang++}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}"
: "${OPENSSL_MODE:=system}" "${OPENSSL_PREFIX:=${MINGW_PREFIX:-/clang64}}"
titan_windows_default_flags NATIVE_CFLAGS '-O2' '-O0 -fno-lto'
titan_windows_default_flags NATIVE_LDFLAGS '' '-O0 -fno-lto'
: "${NATIVE_CPPFLAGS:=}"
export CC CXX AR RANLIB
# CMake owns its normal cache. Clean the build directory for toolchain changes.
CFLAGS="$NATIVE_CPPFLAGS" LDFLAGS="$NATIVE_LDFLAGS" \
  cmake -S vendor/windows-native -B "$work/cmake" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE="$NATIVE_CFLAGS -DNDEBUG" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DTITAN_SOURCE_ROOT="$sources" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB"
cmake --build "$work/cmake" --target titan-native-libraries --parallel "${TITAN_JOBS:-1}"
cmake --install "$work/cmake" --component TitanNativeSDK
case "$OPENSSL_MODE" in
  bundled)
    mkdir -p "$work/openssl"
    if [[ ! -f $work/openssl/Makefile ]]; then
      (cd "$work/openssl"
        RC=llvm-windres CFLAGS="$NATIVE_CFLAGS" CPPFLAGS="$NATIVE_CPPFLAGS" \
        LDFLAGS="$NATIVE_LDFLAGS" perl "$sources/openssl-3.5.7/Configure" mingw64 \
          shared --api=3.0 no-pinshared no-atexit no-apps no-tests no-docs \
          no-legacy no-comp no-dso no-module no-quic no-zlib no-zstd no-brotli \
          no-autoload-config --prefix="$prefix" --openssldir="$prefix/ssl")
    fi
    make -C "$work/openssl" -j1 build_libs
    openssl_bin="$work/openssl"
    openssl_lib="$work/openssl"
    ;;
  system)
    openssl_prefix=$(cd "$(cygpath -u "$OPENSSL_PREFIX")" && pwd)
    # A prebuilt SDK may already live in the selected Lua prefix.
    if [[ $openssl_prefix -ef $prefix ]]; then exit 0; fi
    openssl_bin="$openssl_prefix/bin"
    openssl_lib="$openssl_prefix/lib"
    ;;
  *) echo 'OPENSSL_MODE must be system or bundled' >&2; exit 2 ;;
esac
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/include"
for library in libcrypto libssl; do
  install -m 0755 "$openssl_bin/$library-3-x64.dll" "$prefix/bin/$library-3-x64.dll"
  install -m 0644 "$openssl_lib/$library.dll.a" "$prefix/lib/$library.dll.a"
done
rm -rf "$prefix/include/openssl"
if [[ $OPENSSL_MODE == bundled ]]; then
  mkdir -p "$prefix/include/openssl"
  cp "$sources/openssl-3.5.7/include/openssl/"*.h \
    "$work/openssl/include/openssl/"*.h "$prefix/include/openssl/"
else
  cp -R "$openssl_prefix/include/openssl" "$prefix/include/"
fi

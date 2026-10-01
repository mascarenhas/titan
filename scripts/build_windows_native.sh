#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_native.sh BUILD_ROOT PREFIX' >&2
  exit 2
fi
mkdir -p "$1" "$2"
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
checkout=$PWD
sources="$build_root/native-src"
work="$build_root/native"
mkdir -p "$work"
configuration=$(mktemp "$work/.configuration.XXXXXX")
trap 'rm -f "$configuration"' EXIT
: "${CC:=clang}" "${CXX:=clang++}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}"
: "${NATIVE_CFLAGS:=-O2}" "${NATIVE_CPPFLAGS:=}" "${NATIVE_LDFLAGS:=}"
# CMake and OpenSSL both accept the effective command through their normal
# environment. Changing it rebuilds the owned private directories below.
export CC CXX AR RANLIB
{
  printf '%s\n' 'titan-windows-native-v1' "PREFIX=$prefix" \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
    "CFLAGS=$NATIVE_CFLAGS" "CPPFLAGS=$NATIVE_CPPFLAGS" "LDFLAGS=$NATIVE_LDFLAGS"
  # Parse the compiler command without invoking shell expansion.
  perl -MText::ParseWords=shellwords -e \
    'my @c=shellwords($ENV{CC}); die "Invalid CC\n" unless @c; system(@c,"--version")==0 or die "CC failed\n"'
  cmake --version
  perl -MDigest::SHA -e 'for my $p (@ARGV) { open my $f,"<:raw",$p or die $!; print Digest::SHA->new(256)->addfile($f)->hexdigest,"  ",$p,"\n"; }' \
    scripts/build_windows_native.sh scripts/prepare_windows_native.pl \
    vendor/windows-native/dependencies.tsv vendor/windows-native/CMakeLists.txt
} > "$configuration"
prepare_build_directory() {
  local directory=$1
  if [[ -e $directory ]]; then
    [[ -f $directory/.titan-configuration ]] || {
      echo "Refusing to replace unstamped native build: $directory" >&2; exit 1;
    }
    if ! cmp -s "$configuration" "$directory/.titan-configuration"; then
      rm -rf "$directory"
    fi
  fi
  mkdir -p "$directory"
  cp "$configuration" "$directory/.titan-configuration"
}
prepare_build_directory "$work/cmake"
CFLAGS="$NATIVE_CPPFLAGS" LDFLAGS="$NATIVE_LDFLAGS" \
  cmake -S vendor/windows-native -B "$work/cmake" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE="$NATIVE_CFLAGS -DNDEBUG" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DTITAN_SOURCE_ROOT="$sources" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB"
cmake --build "$work/cmake" --target titan-native-libraries --parallel 1
cmake --install "$work/cmake" --component TitanNativeSDK

prepare_build_directory "$work/openssl"
if [[ ! -f $work/openssl/Makefile ]]; then
  (cd "$work/openssl"
    RC=llvm-windres CFLAGS="$NATIVE_CFLAGS" CPPFLAGS="$NATIVE_CPPFLAGS" \
    LDFLAGS="$NATIVE_LDFLAGS" perl "$sources/openssl-3.5.7/Configure" mingw64 \
      shared --api=3.0 no-pinshared no-atexit no-apps no-tests no-docs \
      no-legacy no-comp no-dso no-module no-quic no-zlib no-zstd no-brotli \
      no-autoload-config --prefix="$prefix" --openssldir="$prefix/ssl")
fi
make -C "$work/openssl" -j1 build_libs
# OpenSSL may create internal static archives; none is installed into the SDK.
install -m 0755 "$work/openssl/libcrypto-3-x64.dll" "$work/openssl/libssl-3-x64.dll" "$prefix/bin/"
install -m 0644 "$work/openssl/libcrypto.dll.a" "$work/openssl/libssl.dll.a" "$prefix/lib/"
mkdir -p "$prefix/include/openssl" "$prefix/etc/titan"
install -m 0644 "$sources/openssl-3.5.7/include/openssl/"*.h "$prefix/include/openssl/"
install -m 0644 "$work/openssl/include/openssl/"*.h "$prefix/include/openssl/"
install -m 0644 "$configuration" "$prefix/etc/titan/native-windows.config"

#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_native.sh PREFIX BUILD_ROOT' >&2
  exit 2
fi
prefix=$(cd "$1" && pwd)
openssl_mode=${OPENSSL_MODE:-system}
case "$openssl_mode" in
  bundled) config_directory=$(cygpath -m "$prefix/ssl") ;;
  system) config_directory=system ;;
  *) echo 'OPENSSL_MODE must be system or bundled' >&2; exit 1 ;;
esac
mkdir -p "$2/native-check"
check_root=$(cd "$2/native-check" && pwd)
run_root=$(mktemp -d "$check_root/runtime.XXXXXX")
mkdir -p "$run_root/bin" "$run_root/unrelated"
selected=$(bash scripts/windows_openssl.sh identify "$prefix/lib" "$prefix/bin")
read -r crypto ssl <<< "$selected"
libraries=(libuv-1.dll libllhttp-9.4.dll libsqlite3-0.dll "$crypto" "$ssl")
for library in "${libraries[@]}"; do cp "$prefix/bin/$library" "$run_root/bin/"; done
# Audit both regular and delayed imports of every packaged private image.
# The sole non-OS destinations allowed here are the five files copied above.
inspect_imports() {
  local file=$1
  llvm-readobj --coff-imports "$file" > "$check_root/${file##*/}.imports"
  perl spec/support/check_windows_native_imports.pl \
    "$crypto" "$ssl" "$check_root/${file##*/}.imports"
}
for file in "$run_root/bin/"*.dll; do
  inspect_imports "$file"
  llvm-readobj --coff-exports "$file" > "$check_root/${file##*/}.exports"
  if grep -F 'ForwardedTo:' "$check_root/${file##*/}.exports"; then
    echo "Unexpected native export forwarder in $file" >&2; exit 1
  fi
done
CC=${CC:-clang} perl -MText::ParseWords=shellwords -e \
  'my @c=shellwords($ENV{CC}); die "Invalid CC\n" unless @c; print "$_\0" for @c' > "$check_root/compiler.argv"
mapfile -d '' -t compiler < "$check_root/compiler.argv"
titan_windows_raw_flags "$check_root" NATIVE
"${compiler[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -Werror -I "$prefix/include" \
  -c spec/fixtures/windows/native_sdk_probe.c -o "$check_root/consumer.o"
llvm-readobj --symbols "$check_root/consumer.o" > "$check_root/consumer.symbols"
for name in llhttp_init llhttp_execute sqlite3_open sqlite3_version uv_loop_init; do
  grep -F "Name: __imp_$name" "$check_root/consumer.symbols" >/dev/null
done
"${compiler[@]}" "${ldflags[@]}" -o "$run_root/bin/native-sdk-probe.exe" "$check_root/consumer.o" \
  "$prefix/lib/libuv.dll.a" "$prefix/lib/libllhttp.dll.a" "$prefix/lib/libsqlite3.dll.a" \
  "$prefix/lib/libssl.dll.a" "$prefix/lib/libcrypto.dll.a"
inspect_imports "$run_root/bin/native-sdk-probe.exe"
# The complete consumer closure is copied into bin; no toolchain PATH entries.
(cd "$run_root/unrelated"; PATH='' "$run_root/bin/native-sdk-probe.exe" "$config_directory")
cygpath -w "$run_root/bin/native-sdk-probe.exe" > "$check_root/native-probe-path.txt"
printf '%s\n' "$config_directory" > "$check_root/native-config-path.txt"
echo 'Native dependency runtime is ready for a separate clean PowerShell run.'

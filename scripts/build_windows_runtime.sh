#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_runtime.sh BUILD_ROOT LUA_SDK' >&2
  exit 2
fi
mkdir -p "$1"
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
work="$build_root/runtime"
if [[ -e $work ]]; then
  [[ -d $work && ! -L $work && -f $work/.titan-runtime-owner ]] || {
    echo "Refusing to use an unowned runtime build directory: $work" >&2; exit 1;
  }
  [[ $(cat "$work/.titan-runtime-owner") == titan-windows-runtime-v1 ]] || exit 1
else
  mkdir "$work"
  printf '%s\n' titan-windows-runtime-v1 > "$work/.titan-runtime-owner"
fi
[[ -f $prefix/etc/titan/lua-5.5.1-windows.config &&
   -f $prefix/lib/liblua-5.5.1.dll.a && -f $prefix/bin/lua55.dll ]]
stage=$(mktemp -d "$work/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
: "${CC:=clang}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}"
: "${RUNTIME_CFLAGS:=-O2 -Wall -Wextra}" "${RUNTIME_CPPFLAGS:=}" "${RUNTIME_LDFLAGS:=}"
export CC AR RANLIB RUNTIME_CFLAGS RUNTIME_CPPFLAGS RUNTIME_LDFLAGS
# Parse configured command/flag strings without evaluating shell substitutions.
for name in CC AR RANLIB RUNTIME_CFLAGS RUNTIME_CPPFLAGS RUNTIME_LDFLAGS; do
  perl -MText::ParseWords=shellwords -e \
    'my $s=$ENV{$ARGV[0]}; my @a=shellwords($s); die "Malformed argument string\n" if $s =~ /\S/ && !@a; die "Empty tool command\n" if $ARGV[0] =~ /^(CC|AR|RANLIB)$/ && !@a; print "$_\0" for @a' \
    "$name" > "$stage/$name.argv"
done
mapfile -d '' -t compiler < "$stage/CC.argv"
mapfile -d '' -t archiver < "$stage/AR.argv"
mapfile -d '' -t indexer < "$stage/RANLIB.argv"
mapfile -d '' -t cflags < "$stage/RUNTIME_CFLAGS.argv"
mapfile -d '' -t cppflags < "$stage/RUNTIME_CPPFLAGS.argv"
mapfile -d '' -t ldflags < "$stage/RUNTIME_LDFLAGS.argv"
[[ $("${compiler[@]}" -dumpmachine) == x86_64-w64-windows-gnu ]]
printf '%s\n' '#include <_mingw.h>' \
  '#if !defined(__clang__) || !defined(_WIN64) || !defined(_UCRT)' \
  '#error Expected native CLANG64/UCRT' '#endif' | \
  "${compiler[@]}" -x c -E - >/dev/null
peg_sources=(lplcap lplcode lplprint lpltree lplvm)
sources=(titan-runtime/titan.c titan-runtime/minicoro.c titan-runtime/ltitanlib.c
  titan-runtime/titan.h titan-runtime/minicoro.h titan-runtime/titan/ffi.h
  titan-runtime/titan_winloader.h titan-runtime/ltitan_winfs.h
  titan-runtime/ltitan_winmeta.h titan-runtime/ltitan_wintool.h
  scripts/build_windows_runtime.sh)
for name in "${peg_sources[@]}"; do sources+=("vendor/lpeglabel/$name.c"); done
sources+=(vendor/lpeglabel/*.h "$prefix/src/lua-5.5.1/"*.h
  "$prefix/lib/liblua-5.5.1.dll.a" "$prefix/bin/lua55.dll")
{
  printf '%s\n' titan-windows-runtime-v1 "PREFIX=$prefix" \
    "CC=$CC" "AR=$AR" "RANLIB=$RANLIB" "CFLAGS=$RUNTIME_CFLAGS" \
    "CPPFLAGS=$RUNTIME_CPPFLAGS" "LDFLAGS=$RUNTIME_LDFLAGS"
  "${compiler[@]}" --version
  "${archiver[@]}" --version
  "${indexer[@]}" --version
  perl -MDigest::SHA -e 'for my $p (@ARGV) { open my $f,"<:raw",$p or die $!; print Digest::SHA->new(256)->addfile($f)->hexdigest,"  ",$p,"\n"; }' "${sources[@]}"
} > "$stage/configuration"
expected_runtime=$(printf '%s\n' titan.o minicoro.o)
expected_peg=$(printf '%s.o\n' "${peg_sources[@]}")
outputs=(titan.o minicoro.o ltitanlib.o libtitan.a libtitan-lpeglabel.a titan.dll)
for name in "${peg_sources[@]}"; do outputs+=("$name.o"); done
output_hashes() {
  (cd "$1"
    perl -MDigest::SHA -e 'for my $p (@ARGV) { open my $f,"<:raw",$p or die $!; print Digest::SHA->new(256)->addfile($f)->hexdigest,"  ",$p,"\n"; }' "${outputs[@]}")
}
warm=1
cmp -s "$stage/configuration" "$work/configuration" || warm=0
for name in "${outputs[@]}"; do
  [[ -f $work/$name && ! -L $work/$name ]] || warm=0
done
if [[ $warm == 1 ]]; then
  [[ $("${archiver[@]}" t "$work/libtitan.a") == "$expected_runtime" ]] || warm=0
  [[ $("${archiver[@]}" t "$work/libtitan-lpeglabel.a") == "$expected_peg" ]] || warm=0
  output_hashes "$work" > "$stage/observed-output-sha256"
  cmp -s "$stage/observed-output-sha256" "$work/output-sha256" || warm=0
fi
if [[ $warm == 1 ]]; then
  echo 'Windows runtime and private PEG payload are current.'
  exit 0
fi
common=(-std=c99 "${cppflags[@]}" "${cflags[@]}" -I titan-runtime -I "$prefix/src/lua-5.5.1")
for name in titan minicoro ltitanlib; do
  "${compiler[@]}" "${common[@]}" -c "titan-runtime/$name.c" -o "$stage/$name.o"
done
"${archiver[@]}" qDc "$stage/libtitan.a" "$stage/titan.o" "$stage/minicoro.o"
"${indexer[@]}" -D "$stage/libtitan.a"
[[ $("${archiver[@]}" t "$stage/libtitan.a") == "$expected_runtime" ]]
peg_objects=()
for name in "${peg_sources[@]}"; do
  "${compiler[@]}" "${common[@]}" -I vendor/lpeglabel \
    -c "vendor/lpeglabel/$name.c" -o "$stage/$name.o"
  peg_objects+=("$stage/$name.o")
done
"${archiver[@]}" qDc "$stage/libtitan-lpeglabel.a" "${peg_objects[@]}"
"${indexer[@]}" -D "$stage/libtitan-lpeglabel.a"
[[ $("${archiver[@]}" t "$stage/libtitan-lpeglabel.a") == "$expected_peg" ]]
"${compiler[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols -Wl,--no-insert-timestamp \
  -o "$stage/titan.dll" "$stage/ltitanlib.o" "$prefix/lib/liblua-5.5.1.dll.a" -lbcrypt
# Accept actual emitted targets and import tables, not just compiler identity.
for object in "$stage/"*.o; do
  llvm-readobj --file-headers "$object" | \
    perl -0777 -e 'local $/; my $s=<>; die "Runtime object is not x64 COFF\n" unless $s =~ /^Format: COFF-x86-64\r?$/m && $s =~ /Machine: IMAGE_FILE_MACHINE_AMD64/;'
done
llvm-readobj --coff-imports "$stage/titan.dll" > "$stage/bootstrap.imports"
perl -0777 -e '
  my $s=<>;
  die "Bootstrap is not x64 COFF\n" unless $s =~ /^Format: COFF-x86-64\r?$/m;
  my @names=$s =~ /^  Name: ([^\r\n]+)\r?$/mg;
  die "Missing bootstrap imports\n" unless @names;
  for my $name (@names) {
    $name=lc $name;
    die "Forbidden runtime DLL: $name\n" unless
      $name =~ /^(kernel32|bcrypt|ucrtbase|lua55)[.]dll$/ ||
      $name =~ /^api-ms-win-crt-[a-z0-9-]+[.]dll$/;
  }
' "$stage/bootstrap.imports"
llvm-readobj --coff-exports "$stage/titan.dll" > "$stage/bootstrap.exports"
perl -0777 -e '
  my $s=<>; my @names=$s =~ /^  Name: ([^\r\n]+)\r?$/mg;
  die "Unexpected bootstrap exports\n" unless @names==1 && $names[0] eq "luaopen_titan" && $s !~ /ForwardedTo:/;
' "$stage/bootstrap.exports"
output_hashes "$stage" > "$stage/output-sha256"
for name in "${outputs[@]}"; do mv -f "$stage/$name" "$work/$name"; done
mv -f "$stage/output-sha256" "$work/output-sha256"
mv -f "$stage/bootstrap.imports" "$stage/bootstrap.exports" "$work/"
mv -f "$stage/configuration" "$work/configuration"
echo 'Built Windows runtime archive, support bootstrap, and private PEG payload.'

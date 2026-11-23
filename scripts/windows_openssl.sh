#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Windows OpenSSL SDK: %s\n' "$*" >&2
  exit 1
}

check_dll() {
  local family=$1 dll=$2 bindir=$3
  [[ $dll =~ ^${family}(-[a-zA-Z0-9][a-zA-Z0-9_.-]*)?[.]dll$ ]] ||
    fail "expected a single $family DLL basename"
  [[ -f $bindir/$dll ]] || fail "missing selected runtime $bindir/$dll"
}

identify() {
  local family=$1 libdir=$2 bindir=$3 raw dll
  local archive="$libdir/$family.dll.a"
  # Keep the terminator so extra lines in tool output cannot disappear from
  # the basename when Bash strips trailing newlines in command substitution.
  raw=$(llvm-dlltool --identify-strict -I "$archive" && printf '.') ||
    fail "cannot identify the import target of $archive"
  case $raw in
    *$'\r\n.') dll=${raw%$'\r\n.'} ;;
    *$'\n.') dll=${raw%$'\n.'} ;;
    *) fail "expected a single import target in $archive" ;;
  esac
  check_dll "$family" "$dll" "$bindir"
  printf '%s\n' "$dll"
}

case ${1-}:$# in
  identify:3)
    crypto=$(identify libcrypto "$2" "$3")
    ssl=$(identify libssl "$2" "$3")
    printf '%s %s\n' "$crypto" "$ssl"
    ;;
  stage:4)
    # `native` already identified the exact pair from the import libraries.
    # Staging is copy-only and need not run a native tool again.
    raw=$(cat "$2" && printf '.') || fail "cannot read native selection $2"
    [[ $raw == *$'\n.' ]] || fail "invalid native selection $2"
    selected=${raw%$'\n.'}
    IFS=' ' read -r crypto ssl extra <<< "$selected"
    [[ $selected == "$crypto $ssl" ]] || fail "invalid native selection $2"
    check_dll libcrypto "$crypto" "$3"
    check_dll libssl "$ssl" "$3"
    cp -p -- "$3/$crypto" "$3/$ssl" "$4/"
    ;;
  *) fail 'usage: windows_openssl.sh identify LIBDIR BINDIR | stage SELECTION BINDIR DESTINATION' ;;
esac

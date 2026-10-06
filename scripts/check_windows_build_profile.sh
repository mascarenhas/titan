#!/usr/bin/env bash
# Portable argv checks; no Windows SDK build or VM execution.
set -eo pipefail
# Match the repository's portable-shell policy for empty arrays before Bash 4.4.
if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  set -u
else
  set +u
fi
source "$(dirname "$0")/windows_build_profile.sh"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
unset TITAN_BUILD_PROFILE TEST_CFLAGS TEST_CPPFLAGS TEST_LDFLAGS
unset TITAN_EXTRA_CFLAGS TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_LDFLAGS

(
  titan_windows_profile production
  titan_windows_raw_flags "$stage" TEST
  [[ $TITAN_BUILD_PROFILE == production && ${cflags[*]} == -O2 &&
     ${#cppflags[@]} == 0 && ${#ldflags[@]} == 0 ]]
)
(
  titan_windows_profile validation
  titan_windows_raw_flags "$stage" TEST
  [[ ${cflags[*]} == '-O0 -fno-lto' && ${ldflags[*]} == '-O0 -fno-lto' ]]
  first=$TEST_CFLAGS
  titan_windows_raw_flags "$stage" TEST
  [[ $TEST_CFLAGS == "$first" ]]
)
(
  export TITAN_BUILD_PROFILE=validation
  titan_windows_profile production
  export TEST_CFLAGS='-O1 -fsanitize=address "-DNOTE=two words"'
  export TEST_LDFLAGS='-fsanitize=address'
  export TITAN_EXTRA_CFLAGS='-O2'
  export TITAN_EXTRA_CPPFLAGS='"-DVALUE=$(do-not-evaluate)" ""'
  export TITAN_EXTRA_LDFLAGS='"C:/SDK space/lib/fixture.dll.a"'
  titan_windows_raw_flags "$stage" TEST
  [[ ${cflags[*]} == '-O0 -fno-lto -O1 -fsanitize=address -DNOTE=two words -O2' &&
     ${#cflags[@]} == 6 && ${cflags[4]} == '-DNOTE=two words' ]]
  [[ ${#cppflags[@]} == 2 && ${cppflags[0]} == '-DVALUE=$(do-not-evaluate)' &&
     ${cppflags[1]} == '' ]]
  [[ ${ldflags[0]} == -O0 && ${ldflags[1]} == -fno-lto &&
     ${ldflags[2]} == -fsanitize=address &&
     ${ldflags[3]} == 'C:/SDK space/lib/fixture.dll.a' ]]
  first=$TEST_CFLAGS
  titan_windows_raw_flags "$stage" TEST
  [[ $TEST_CFLAGS == "$first" ]]
)
(
  export TITAN_BUILD_PROFILE=production TEST_CFLAGS='' TEST_LDFLAGS=''
  titan_windows_profile validation
  titan_windows_raw_flags "$stage" TEST
  [[ ${#cflags[@]} == 0 && ${#ldflags[@]} == 0 ]]
)
for invalid in '' optimized Validation; do
  if (export TITAN_BUILD_PROFILE=$invalid; titan_windows_profile validation) \
      > "$stage/invalid.log" 2>&1; then
    echo "Invalid profile accepted: $invalid" >&2; exit 1
  fi
  [[ $(cat "$stage/invalid.log") == 'TITAN_BUILD_PROFILE must be production or validation' ]]
done
(
  export TITAN_BUILD_PROFILE=validation TEST_CFLAGS='"unterminated'
  titan_windows_profile validation
  if titan_windows_raw_flags "$stage" TEST > "$stage/malformed.log" 2>&1; then
    echo 'Malformed quoted flags accepted' >&2; exit 1
  fi
  [[ $(cat "$stage/malformed.log") == 'Malformed argument string: TEST_CFLAGS' ]]
)
# Host suffixes override generic test optimization while retaining argv and
# instrumentation. The runtime link remains O0 when only its private PEG is host.
(
  unset HOST_CFLAGS HOST_LDFLAGS
  export TITAN_BUILD_PROFILE=production
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS HOST_LDFLAGS
  [[ ${cflags[*]} == '-O2' && ${#ldflags[@]} == 0 ]]
)
(
  unset HOST_CFLAGS HOST_LDFLAGS
  export TITAN_BUILD_PROFILE=validation TITAN_EXTRA_CFLAGS='-O0'
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS HOST_LDFLAGS
  [[ ${cflags[*]} == '-O0 -fno-lto -O0 -O2 -fno-lto' &&
     ${ldflags[*]} == '-O0 -fno-lto -O2 -fno-lto' ]]
  first=$HOST_CFLAGS
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS HOST_LDFLAGS
  [[ $HOST_CFLAGS == "$first" ]]
)
(
  unset HOST_CFLAGS
  export TITAN_BUILD_PROFILE=validation
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS
  [[ ${cflags[*]} == '-O0 -fno-lto -O2 -fno-lto' &&
     ${ldflags[*]} == '-O0 -fno-lto' ]]
)
(
  export TITAN_BUILD_PROFILE=validation TITAN_EXTRA_CFLAGS='-O0 -fsanitize=address,undefined'
  export TITAN_EXTRA_LDFLAGS='-fsanitize=address,undefined'
  export HOST_CFLAGS='-O1 -fno-lto -fsanitize=address,undefined "-DHOST=two words"'
  export HOST_LDFLAGS='-O1 -fno-lto -fsanitize=address,undefined'
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS HOST_LDFLAGS
  [[ ${cflags[*]} == '-O0 -fno-lto -O0 -fsanitize=address,undefined -O2 -fno-lto -O1 -fno-lto -fsanitize=address,undefined -DHOST=two words' &&
     ${cflags[9]} == '-DHOST=two words' ]]
  [[ ${ldflags[*]} == '-O0 -fno-lto -fsanitize=address,undefined -O2 -fno-lto -O1 -fno-lto -fsanitize=address,undefined' ]]
)
(
  export TITAN_BUILD_PROFILE=production TEST_CFLAGS='' TEST_LDFLAGS='' HOST_CFLAGS='' HOST_LDFLAGS=''
  titan_windows_host_flags "$stage" TEST HOST_CFLAGS HOST_LDFLAGS
  [[ ${#cflags[@]} == 0 && ${#ldflags[@]} == 0 ]]
)
echo 'Windows profile defaults, host optimization, overrides, quoted/empty argv, strict validation and idempotent flag propagation passed.'

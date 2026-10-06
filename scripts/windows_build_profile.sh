#!/usr/bin/env bash
# Shared profile/argv policy for native Windows build and check scripts.
# Callers supply ordinary production defaults; explicit flags stay last.
titan_windows_profile() {
  export TITAN_BUILD_PROFILE=${TITAN_BUILD_PROFILE-$1}
  case $TITAN_BUILD_PROFILE in
    production|validation) ;;
    *) echo 'TITAN_BUILD_PROFILE must be production or validation' >&2; return 2 ;;
  esac
}

titan_windows_default_flags() {
  local name=$1 production=$2 validation=$3 value
  if [[ ${!name+x} ]]; then value=${!name}; else value=$production; fi
  if [[ $TITAN_BUILD_PROFILE == validation ]]; then
    if [[ ! ${!name+x} ]]; then value=$validation
    elif [[ -n $validation && $value != "$validation" && $value != "$validation "* ]]; then
      value="$validation${value:+ $value}"
    fi
  fi
  printf -v "$name" '%s' "$value"
  export "$name"
}

titan_windows_read_flags() {
  local output=$1 destination=$2
  shift 2
  perl -MText::ParseWords=shellwords -e '
    for my $name (@ARGV) {
      my $s=$ENV{$name} // ""; my @a=shellwords($s);
      die "Malformed argument string: $name\n" if $s =~ /\S/ && !@a;
      print "$_\0" for @a;
    }' "$@" > "$destination" || return
  # Fixed destinations retain quoted and empty words without eval or namerefs.
  # These loops also run under the system Bash 3.2 used by portable macOS checks.
  case $output in
    cflags) cflags=() ;;
    cppflags) cppflags=() ;;
    ldflags) ldflags=() ;;
    *) echo "Unknown flags destination: $output" >&2; return 2 ;;
  esac
  local word
  while IFS= read -r -d '' word; do
    case $output in
      cflags) cflags+=("$word") ;;
      cppflags) cppflags+=("$word") ;;
      ldflags) ldflags+=("$word") ;;
    esac
  done < "$destination"
}

titan_windows_raw_flags() {
  local stage=$1 category=$2
  titan_windows_default_flags "${category}_CFLAGS" '-O2' '-O0 -fno-lto'
  titan_windows_default_flags "${category}_CPPFLAGS" '' ''
  titan_windows_default_flags "${category}_LDFLAGS" '' '-O0 -fno-lto'
  titan_windows_read_flags cflags "$stage/cflags.argv" "${category}_CFLAGS" TITAN_EXTRA_CFLAGS || return
  titan_windows_read_flags cppflags "$stage/cppflags.argv" "${category}_CPPFLAGS" TITAN_EXTRA_CPPFLAGS || return
  titan_windows_read_flags ldflags "$stage/ldflags.argv" "${category}_LDFLAGS" TITAN_EXTRA_LDFLAGS || return
}

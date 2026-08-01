#!/usr/bin/env bash

set -u -o pipefail

if (( $# < 2 )); then
    echo "usage: $0 <label> <command> [argument ...]" >&2
    exit 2
fi
if [[ ! $1 =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "invalid sanitizer log label: $1" >&2
    exit 2
fi
if [[ -z ${TITAN_SANITIZER_LOG_DIR:-} ]]; then
    echo "TITAN_SANITIZER_LOG_DIR is not set" >&2
    exit 2
fi

label=$1
shift
mkdir -p "$TITAN_SANITIZER_LOG_DIR"
"$@" 2>&1 | tee "$TITAN_SANITIZER_LOG_DIR/$label.log"

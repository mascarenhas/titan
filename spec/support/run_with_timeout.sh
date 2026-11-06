#!/usr/bin/env bash

# Run one command in its own process group, checking completion every 100 ms
# while bounding hung native tests and their descendants.

set -u

if [[ $# -lt 2 || ! $1 =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 SECONDS COMMAND [ARG ...]" >&2
    exit 2
fi

timeout=$1
shift

set -m
"$@" &
child=$!
set +m

group_alive() {
    kill -0 -- "-$child" 2>/dev/null || kill -0 "$child" 2>/dev/null
}

signal_group() {
    local signal=$1
    kill -"$signal" -- "-$child" 2>/dev/null ||
        kill -"$signal" "$child" 2>/dev/null || true
}

stop_group() {
    signal_group TERM
    local grace=$((SECONDS + 3))
    while group_alive && (( SECONDS < grace )); do sleep 1; done
    if group_alive; then signal_group KILL; fi
}

interrupt() {
    stop_group
    wait "$child" 2>/dev/null || true
    exit 130
}
trap interrupt HUP INT TERM

deadline=$((SECONDS + timeout))
while kill -0 "$child" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        printf 'native Titan test deadline exceeded after %ss:' "$timeout" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        stop_group
        wait "$child" 2>/dev/null || true
        exit 124
    fi
    sleep 0.1
done

wait "$child" 2>/dev/null
status=$?
if group_alive; then stop_group; fi
exit "$status"

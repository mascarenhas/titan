#!/bin/sh
# A real C compiler with deterministic C-probe verdicts for the speculative
# probe specs. Only Titan probe translation units are inspected: one naming a
# `speculative_reject` type is rejected, one naming `speculative_missing`
# reports an unavailable command, and every other probe and every generated
# module compile through the configured compiler.
#
# Two probe forms fail as infrastructure once per probe workspace and exact
# source by default, then compile normally (a fail-once/recover compiler): a probe
# naming `speculative_flaky` outside its `#include` lines, and a header
# baseline (`titan_probe_b`) naming `speculative_flaky_baseline`. A numeric
# suffix (`speculative_flaky_baseline_2`) selects that many baseline failures.
# A baseline naming `speculative_broken_baseline` is always rejected. Module
# probes include `<module>.ffi.h`, so the module name selects this policy.
#
# SPECULATIVE_PROBE_STATE, when set, names a directory that records each probe
# and the maximum number of overlapping probe compilers; SPECULATIVE_PROBE_DELAY
# keeps each probe alive long enough for overlap to be observable, and
# SPECULATIVE_PROBE_EXPECTED holds every C-operator probe until that many have
# started, so a batch must really overlap that many compilers.
set -u

source=
previous=
for argument in "$@"; do
    if [ "$previous" = "-c" ]; then source=$argument; fi
    previous=$argument
done

probe=no
if [ -n "$source" ] && grep -q 'titan_probe_' "$source" 2>/dev/null; then
    probe=yes
fi

state=${SPECULATIVE_PROBE_STATE:-}
lock() {
    while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done
}
unlock() {
    rmdir "$state/lock"
}

if [ "$probe" = yes ] && [ -n "$state" ]; then
    lock
    active=0
    test ! -f "$state/active" || active=$(cat "$state/active")
    active=$((active + 1))
    printf '%s\n' "$active" > "$state/active"
    maximum=0
    test ! -f "$state/maximum" || maximum=$(cat "$state/maximum")
    if [ "$active" -gt "$maximum" ]; then
        printf '%s\n' "$active" > "$state/maximum"
    fi
    printf '%s\n' "$source" >> "$state/probes"
    case "$source" in
        *-c-operator.c)
            started=0
            test ! -f "$state/started" || started=$(cat "$state/started")
            printf '%s\n' "$((started + 1))" > "$state/started"
            ;;
    esac
    unlock
    case "$source" in
        *-c-operator.c)
            attempts=0
            while :; do
                lock
                started=$(cat "$state/started")
                unlock
                test "$started" -lt "${SPECULATIVE_PROBE_EXPECTED:-1}" || break
                attempts=$((attempts + 1))
                if test "$attempts" -ge 1000; then
                    echo "speculative probe barrier timed out" >&2
                    exit 24
                fi
                sleep 0.01
            done
            ;;
    esac
    sleep "${SPECULATIVE_PROBE_DELAY:-0}"
fi

flaky=no
failures=1
if [ "$probe" = yes ]; then
    if grep -v '^#include' "$source" | grep -q 'speculative_flaky'; then
        flaky=yes
    elif grep -q 'titan_probe_b' "$source" &&
            grep -q 'speculative_flaky_baseline' "$source"; then
        flaky=yes
        selected=$(grep -o 'speculative_flaky_baseline_[0-9][0-9]*' "$source" | cut -d_ -f4)
        failures=${selected:-1}
    fi
fi
if [ "$flaky" = yes ]; then
    mark="$(dirname "$source")/.flaky-$(cksum < "$source" | cut -d ' ' -f 1)"
    failed=0
    test ! -s "$mark" || failed=$(cat "$mark")
    if [ "$failed" -ge "$failures" ]; then
        flaky=no
    else
        printf '%s\n' "$((failed + 1))" > "$mark"
    fi
fi

status=0
if [ "$probe" = yes ] && grep -q 'speculative_reject' "$source"; then
    echo "$source:1:1: error: rejected by the speculative probe test compiler" >&2
    status=1
elif [ "$probe" = yes ] && grep -q 'speculative_missing' "$source"; then
    echo "speculative probe test compiler: command not found" >&2
    status=127
elif [ "$flaky" = yes ]; then
    echo "speculative probe test compiler: transient failure" >&2
    status=127
elif [ "$probe" = yes ] && grep -q 'titan_probe_b' "$source" &&
        grep -q 'speculative_broken_baseline' "$source"; then
    echo "$source:1:1: error: broken baseline for the speculative probe test compiler" >&2
    status=1
else
    "${SPECULATIVE_PROBE_CC:-cc}" "$@" || status=$?
fi

if [ "$probe" = yes ] && [ -n "$state" ]; then
    lock
    active=$(cat "$state/active")
    printf '%s\n' "$((active - 1))" > "$state/active"
    unlock
fi
exit "$status"

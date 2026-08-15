#!/bin/sh
set -eu

state=${TITAN_PARALLEL_TEST_STATE:?}
matched=no
source=
for argument in "$@"; do
    case "$argument" in
        */batch/one.c | */batch/two.c | */batch/three.c | */batch/four.c | \
        */batch/five.c | */batch/six.c | */batch/seven.c | */batch/eight.c)
            matched=yes
            source=$argument
            ;;
    esac
done

lock() {
    while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done
}
unlock() {
    rmdir "$state/lock"
}

if [ "$matched" = yes ]; then
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
    printf '%s\n' "$*" >> "$state/commands"
    started=0
    test ! -f "$state/started" || started=$(cat "$state/started")
    ordinal=$((started + 1))
    printf '%s\n' "$ordinal" > "$state/started"
    if [ "${TITAN_PARALLEL_TEST_MODE:-}" = refill ] &&
            [ "$ordinal" -ge 5 ] && [ ! -f "$state/slow-finished" ]; then
        : > "$state/refilled-before-slow-finished"
    fi
    unlock

    expected=${TITAN_PARALLEL_TEST_EXPECTED:-1}
    attempts=0
    while :; do
        lock
        started=$(cat "$state/started")
        unlock
        test "$started" -lt "$expected" || break
        attempts=$((attempts + 1))
        if test "$attempts" -ge 1000; then
            echo "parallel compiler barrier timed out" >&2
            exit 24
        fi
        sleep 0.01
    done

    delay=${TITAN_PARALLEL_TEST_DELAY:-0.5}
    leaf=${source##*/}
    leaf=${leaf%.c}
    if [ "${TITAN_PARALLEL_TEST_MODE:-}" = refill ]; then
        case "$leaf" in
            one) delay=1 ;;
            *) delay=0.1 ;;
        esac
    fi
    if [ "${TITAN_PARALLEL_TEST_DIAGNOSTICS:-}" = reverse ]; then
        case "$leaf" in
            four) delay=0.4 ;;
            one) delay=0.3 ;;
            three) delay=0.2 ;;
            two) delay=0.1 ;;
        esac
    fi
    sleep "$delay"
    if [ -n "${TITAN_PARALLEL_TEST_DIAGNOSTICS:-}" ]; then
        echo "parallel compiler diagnostic: $leaf" >&2
    fi

    lock
    if [ "${TITAN_PARALLEL_TEST_MODE:-}" = refill ] && [ "$leaf" = one ]; then
        : > "$state/slow-finished"
    fi
    active=$(cat "$state/active")
    printf '%s\n' $((active - 1)) > "$state/active"
    unlock

    if [ -n "${TITAN_PARALLEL_TEST_FAIL:-}" ]; then
        case "$source" in
            */"$TITAN_PARALLEL_TEST_FAIL".c)
                echo "parallel compiler sentinel: $TITAN_PARALLEL_TEST_FAIL" >&2
                exit 23
                ;;
        esac
    fi
fi

exec cc "$@"

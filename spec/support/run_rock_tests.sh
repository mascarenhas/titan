#!/usr/bin/env bash

# LuaRocks appends `luarocks test -- ...` arguments to its command backend.
# Carry those exact arguments through the required Make entry point, then use
# them only for the retained Busted suite. Native Titan filtering has its own
# direct group runner.

set -u

if [[ ${TITAN_ROCK_TEST_INTERNAL:-0} != 1 ]]; then
    export TITAN_ROCK_TEST_FORWARDED=1
    export TITAN_ROCK_TEST_ARGC=$#
    index=0
    for argument in "$@"; do
        printf -v name 'TITAN_ROCK_TEST_ARG_%d' "$index"
        printf -v "$name" '%s' "$argument"
        export "$name"
        index=$((index + 1))
    done
    exec make rock-test
fi

busted_args=()
if [[ ${TITAN_ROCK_TEST_FORWARDED:-0} == 1 ]]; then
    count=${TITAN_ROCK_TEST_ARGC:-0}
    for ((index = 0; index < count; index++)); do
        printf -v name 'TITAN_ROCK_TEST_ARG_%d' "$index"
        busted_args+=("${!name}")
    done
fi
busted_args+=("$@")

BUSTED=${BUSTED:-busted}
busted_status=0
native_status=0
"$BUSTED" "${busted_args[@]}" || busted_status=$?
bash spec/support/run_titan_stdlib_test_groups.sh all || native_status=$?
if (( busted_status != 0 || native_status != 0 )); then
    echo "rock test status: busted=$busted_status native=$native_status" >&2
    exit 1
fi

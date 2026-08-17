#!/usr/bin/env bash

# LuaRocks appends `luarocks test -- ...` arguments to its command backend.
# Carry ordinary arguments byte-for-byte through Make for Busted while giving
# each test system an independent filter.

set -euo pipefail

if [[ ${TITAN_ROCK_TEST_INTERNAL:-0} == 1 ]]; then
    busted_args=()
    forwarded_count=0
    if [[ ${TITAN_ROCK_TEST_FORWARDED:-0} == 1 ]]; then
        count=${TITAN_ROCK_TEST_ARGC:-}
        [[ $count =~ ^[0-9]+$ ]] || {
            echo "error: invalid forwarded Busted argument count" >&2
            exit 2
        }
        forwarded_count=$count
        for ((index = 0; index < count; index++)); do
            printf -v name 'TITAN_ROCK_TEST_ARG_%d' "$index"
            busted_args+=("${!name}")
        done
    fi
    busted_args+=("$@")
    if (( forwarded_count == 0 && $# == 0 )) &&
        [[ -z ${BUSTED_FILTER:-} ]]; then
        # This value is supplied by Make from its fixed, whitespace-free
        # repository paths. Keep the retained runtime/packaging specs serial
        # before the isolated compiler workers start.
        stdlib_spec_list=${TITAN_ROCK_TEST_STDLIB_SPECS:-}
        stdlib_specs=()
        IFS=' ' read -r -a stdlib_specs <<< "$stdlib_spec_list"
        if (( ${#stdlib_specs[@]} != 8 )); then
            echo "error: invalid retained Busted spec list" >&2
            exit 2
        fi
        export TITAN_PROBE_CACHE_DISABLE=1
        "${BUSTED:-busted}" "${stdlib_specs[@]}"
        exec bash spec/support/run_parallel_compiler_tests.sh
    fi
    if [[ -n ${BUSTED_FILTER:-} ]]; then
        busted_args+=("--filter=$BUSTED_FILTER")
    fi
    # Compiler specs intentionally reuse pathnames for different header worlds;
    # exact-text success markers are production build state, not test fixtures.
    export TITAN_PROBE_CACHE_DISABLE=1
    exec "${BUSTED:-busted}" "${busted_args[@]}"
fi

busted_filter=${BUSTED_FILTER:-}
titan_filter=${TITAN_FILTER:-}
busted_args=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --busted-filter)
            [[ $# -ge 2 ]] || {
                echo "error: --busted-filter requires a pattern" >&2
                exit 2
            }
            busted_filter=$2
            shift 2
            ;;
        --busted-filter=*)
            busted_filter=${1#*=}
            shift
            ;;
        --titan-filter)
            [[ $# -ge 2 ]] || {
                echo "error: --titan-filter requires a pattern" >&2
                exit 2
            }
            titan_filter=$2
            shift 2
            ;;
        --titan-filter=*)
            titan_filter=${1#*=}
            shift
            ;;
        *)
            busted_args+=("$1")
            shift
            ;;
    esac
done

export BUSTED_FILTER="$busted_filter"
export TITAN_FILTER="$titan_filter"
export TITAN_ROCK_TEST_FORWARDED=1
export TITAN_ROCK_TEST_ARGC=${#busted_args[@]}
for index in "${!busted_args[@]}"; do
    printf -v name 'TITAN_ROCK_TEST_ARG_%d' "$index"
    printf -v "$name" '%s' "${busted_args[$index]}"
    export "$name"
done
exec make rock-test

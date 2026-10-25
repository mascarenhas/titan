#!/usr/bin/env bash

# LuaRocks appends `luarocks test -- ...` arguments to its command backend.
# Carry ordinary arguments byte-for-byte through Make for Busted while giving
# each test system an independent filter.

set -euo pipefail

export TITAN_BUILD_PROFILE=${TITAN_BUILD_PROFILE-validation}
case $TITAN_BUILD_PROFILE in
    production|validation) ;;
    *) echo 'TITAN_BUILD_PROFILE must be production or validation' >&2; exit 2 ;;
esac

if [[ ${TITAN_ROCK_TEST_INTERNAL:-0} == 1 ]]; then
    run_busted() {
        if [[ ${MSYSTEM:-} == CLANG64 ]]; then
            # LuaRocks' native .bat launcher is not a Bash program. Preserve
            # stock Lua module paths by running its script with the selected Lua.
            export PATH="$(cygpath -u "$PREFIX")/bin:$PATH"
            export PREFIX=$(cygpath -m "$PREFIX")
            local -a busted_scripts
            busted_scripts=("$PREFIX"/lib/luarocks/rocks-5.5/busted/*/bin/busted)
            # Busted must retain luv's loop while insulating test files.
            "$PREFIX/bin/lua.exe" -l luv -e 'io.stdout:setvbuf("no"); io.stderr:setvbuf("no")' \
                "$(cygpath -m "${busted_scripts[0]}")" "$@"
        else
            "${BUSTED:-busted}" "$@"
        fi
    }
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
        # repository paths. The parallel compiler/runtime launcher schedules
        # the retained runtime/packaging specs, stdlib-compiler integrations,
        # and compiler specs per file across isolated checkout workers.
        stdlib_spec_list=${TITAN_ROCK_TEST_STDLIB_SPECS:-}
        [[ -n $stdlib_spec_list ]] || {
            echo "error: Make must select the retained runtime/packaging specs" >&2
            exit 2
        }
        while read -r test_file extra; do
            if [[ -z ${test_file:-} || $test_file == \#* ]]; then continue; fi
            [[ $test_file == spec/*_spec.lua && -z ${extra:-} ]] || {
                echo "error: invalid stdlib compiler spec: $test_file ${extra:-}" >&2
                exit 2
            }
        done < spec/support/ci_stdlib_compiler_test_files.txt
        export TITAN_PROBE_CACHE_DISABLE=1
        export TITAN_ROCK_TEST_STDLIB_SPECS="$stdlib_spec_list"
        exec bash spec/support/run_parallel_compiler_tests.sh
    fi
    if [[ -n ${BUSTED_FILTER:-} ]]; then
        busted_args+=("--filter=$BUSTED_FILTER")
    fi
    # Compiler specs intentionally reuse pathnames for different header worlds;
    # exact-text success markers are production build state, not test fixtures.
    export TITAN_PROBE_CACHE_DISABLE=1
    run_busted "${busted_args[@]}"
    exit $?
fi

busted_filter=${BUSTED_FILTER:-}
titan_filter=${TITAN_FILTER:-}
make_command=make
busted_args=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix=*)
            export PREFIX=${1#*=}
            shift
            ;;
        --make=*)
            make_command=${1#*=}
            shift
            ;;
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
if [[ ${MSYSTEM:-} == CLANG64 ]]; then
    export PREFIX=$(cygpath -u "$PREFIX")
    export PATH="$PREFIX/bin:$PATH"
    exec "$make_command" -f Makefile.win rock-test PREFIX="$PREFIX" ROCKS_TREE="$PREFIX"
fi
exec "$make_command" rock-test

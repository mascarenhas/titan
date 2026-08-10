#!/usr/bin/env bash

# Build and run one native Titan standard-library behavior suite. Test sources
# are explicit because generated compiler artifacts must be cleaned exactly;
# never replace these lists with a repository-wide C/object glob.

set -euo pipefail

suite=${1:-}
if [[ $# -gt 0 ]]; then shift; fi

TITANC=${TITANC:-titanc}
PYTHON=${PYTHON:-python3}
TEST_TIMEOUT_SECONDS=${TITAN_TEST_TIMEOUT_SECONDS:-120}
SHUTDOWN_TIMEOUT_SECONDS=${TITAN_TEST_SHUTDOWN_TIMEOUT_SECONDS:-15}
TIMEOUT_RUNNER=spec/support/run_with_timeout.py
if [[ -n ${TITAN_TEST_EXTRA_CPPFLAGS:-} &&
      -z ${TITAN_EXTRA_CPPFLAGS+x} ]]; then
    export TITAN_EXTRA_CPPFLAGS=$TITAN_TEST_EXTRA_CPPFLAGS
fi
if [[ -n ${TITAN_TEST_EXTRA_CFLAGS:-} &&
      -z ${TITAN_EXTRA_CFLAGS+x} ]]; then
    export TITAN_EXTRA_CFLAGS=$TITAN_TEST_EXTRA_CFLAGS
fi
if [[ -n ${TITAN_TEST_EXTRA_LDFLAGS:-} &&
      -z ${TITAN_EXTRA_LDFLAGS+x} ]]; then
    export TITAN_EXTRA_LDFLAGS=$TITAN_TEST_EXTRA_LDFLAGS
fi

tree=
output=
roots=()
sources=()

# Combined selectors below are host process cohorts only. Their roots remain
# independent qualified test modules and therefore retain module-owned names.
case "$suite" in
    iter)
        tree=spec/stdlib/titan
        output=iter/tests
        roots=(iter.tests)
        sources=(
            spec/stdlib/titan/iter/tests
            spec/stdlib/titan/support/common
        )
        ;;
    gc)
        tree=spec/stdlib/titan
        output=gc/tests
        roots=(gc.tests)
        sources=(
            spec/stdlib/titan/gc/tests
            spec/stdlib/titan/support/common
        )
        ;;
    lua)
        tree=spec/stdlib/titan
        output=lua/tests__main
        roots=(lua.tests)
        sources=(
            spec/stdlib/titan/lua/tests/tests
            spec/stdlib/titan/lua/test_support
            spec/stdlib/titan/support/async
            spec/stdlib/titan/support/common
        )
        ;;
    math)
        tree=spec/stdlib/titan
        output=math/tests
        roots=(math.tests)
        sources=(spec/stdlib/titan/math/tests)
        ;;
    peg)
        tree=spec/stdlib/titan
        output=peg/tests__main
        roots=(peg.tests)
        sources=(
            spec/stdlib/titan/peg/tests/tests
            spec/stdlib/titan/peg/test_support
        )
        ;;
    string)
        tree=spec/stdlib/titan
        output=string/core_test
        roots=(string.core_test string.format_pack_test string.regex_test)
        sources=(
            spec/stdlib/titan/string/core_test
            spec/stdlib/titan/string/format_pack_test
            spec/stdlib/titan/string/regex_test
            spec/stdlib/titan/string/test_support
        )
        ;;
    url)
        tree=spec/stdlib/titan
        output=url/tests
        roots=(url.tests)
        sources=(spec/stdlib/titan/url/tests)
        ;;
    coroutine)
        tree=spec/stdlib/titan
        output=coroutine/tests__main
        roots=(coroutine.tests)
        sources=(
            spec/stdlib/titan/coroutine/tests/tests
            spec/stdlib/titan/coroutine/test_support
        )
        ;;
    async)
        tree=spec/stdlib/titan
        output=async/tests__main
        roots=(async.tests)
        sources=(
            spec/stdlib/titan/async/tests/tests
            spec/stdlib/titan/async/test_support
            spec/stdlib/titan/support/async
        )
        ;;
    http)
        tree=spec/stdlib/titan
        output=http/tests__main
        roots=(http.tests)
        sources=(
            spec/stdlib/titan/http/tests/tests
            spec/stdlib/titan/http/test_support
            spec/stdlib/titan/support/async
        )
        ;;
    net-ssl)
        tree=spec/stdlib/titan
        output=net/tests
        roots=(net.tests ssl.tests)
        sources=(
            spec/stdlib/titan/net/tests
            spec/stdlib/titan/net/test_support
            spec/stdlib/titan/ssl/tests
            spec/stdlib/titan/ssl/test_support
            spec/stdlib/titan/support/async
        )
        ;;
    uv-tasks)
        tree=spec/stdlib/titan
        output=uv/task_tests__main
        roots=(uv.task_tests)
        sources=(
            spec/stdlib/titan/uv/task_tests/task_tests
            spec/stdlib/titan/uv/task_test_support
            spec/stdlib/titan/support/async
        )
        ;;
    uv-runtime)
        tree=spec/stdlib/titan
        output=uv/runtime_tests
        roots=(uv.runtime_tests)
        sources=(spec/stdlib/titan/uv/runtime_tests)
        ;;
    io-fs-timer)
        tree=spec/stdlib/titan
        output=io/tests__main
        roots=(io.tests fs.tests timer.tests)
        sources=(
            spec/stdlib/titan/io/tests/tests
            spec/stdlib/titan/io/test_support
            spec/stdlib/titan/fs/tests
            spec/stdlib/titan/fs/test_support
            spec/stdlib/titan/timer/tests
            spec/stdlib/titan/support/async
        )
        ;;
    os)
        tree=spec/stdlib/titan
        output=os/tests__main
        roots=(os.tests)
        sources=(
            spec/stdlib/titan/os/tests/tests
            spec/stdlib/titan/os/test_support
        )
        ;;
    os-process)
        tree=spec/stdlib/titan
        output=os/process_tests__main
        roots=(os.process_tests)
        sources=(
            spec/stdlib/titan/os/process_tests/process_tests
            spec/stdlib/titan/os/process_test_support
            spec/stdlib/titan/support/async
        )
        ;;
    *)
        echo "usage: $0 {iter|gc|lua|math|peg|string|url|coroutine|async|http|net-ssl|uv-tasks|uv-runtime|io-fs-timer|os|os-process} [runner-options...]" >&2
        exit 2
        ;;
esac

cleanup() {
    local source
    rm -f -- "$output" \
        "${output}__test_support.c" "${output}__test_support.o" \
        "${output}__test_runner.c" "${output}__test_runner.o" \
        "${output}__test_entrypoint.c" "${output}__test_entrypoint.o"
    rm -rf -- "${output}.dSYM"
    for source in "${sources[@]}"; do
        rm -f -- "${source}.c" "${source}.o"
    done
    # The compiler creates a parent for nested outputs. Remove that immediate
    # parent only when every exact owned leaf is gone; pre-existing nonempty
    # directories are preserved by rmdir. A root-level output has no generated
    # parent to remove.
    if [[ "$output" == */* ]]; then
        rmdir -- "${output%/*}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
cleanup

"$TITANC" --test --tree "$tree" "${roots[@]}"

run_test_program() {
    local timeout=$TEST_TIMEOUT_SECONDS
    if [[ ${1:-} == "--filter=test_runtime_shutdown_closes_native_handles_but_not_files" ]]; then
        timeout=$SHUTDOWN_TIMEOUT_SECONDS
    fi
    "$PYTHON" "$TIMEOUT_RUNNER" "$timeout" "./$output" "$@"
}

if [[ ${1:-} == --also-each-filter || ${1:-} == --each-filter-only ]]; then
    mode=$1
    shift
    if [[ $mode == --also-each-filter ]]; then run_test_program; fi
    for filter in "$@"; do
        [[ $filter =~ ^[A-Za-z0-9_]+$ ]] || {
            echo "invalid Titan test filter name: $filter" >&2
            exit 2
        }
        printf '\n===== TITAN FILTER %s =====\n' "$filter"
        run_test_program "--filter=$filter"
    done
else
    run_test_program "$@"
fi

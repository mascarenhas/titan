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
synthetic_parent=

case "$suite" in
    pure)
        tree=spec/stdlib/titan
        output=pure__main
        roots=(pure)
        sources=(spec/stdlib/titan/pure/pure)
        ;;
    math)
        tree=spec/stdlib/titan
        output=math_native__main
        roots=(math_native)
        sources=(spec/stdlib/titan/math_native/math_native)
        ;;
    peg)
        tree=spec/stdlib/titan
        output=peg/tests__main
        roots=(peg.tests)
        sources=(spec/stdlib/titan/peg/tests/tests)
        synthetic_parent=peg
        ;;
    string)
        tree=spec/stdlib/titan/string_url
        output=string_core_test
        roots=(string_core_test string_format_pack_test string_regex_test)
        sources=(
            spec/stdlib/titan/string_url/string_core_test
            spec/stdlib/titan/string_url/string_format_pack_test
            spec/stdlib/titan/string_url/string_regex_test
            spec/stdlib/titan/string_url/string_url_support
        )
        ;;
    url)
        tree=spec/stdlib/titan/string_url
        output=url_test
        roots=(url_test)
        sources=(spec/stdlib/titan/string_url/url_test)
        ;;
    coroutine)
        tree=spec/stdlib/titan
        output=coroutine_native__main
        roots=(coroutine_native)
        sources=(spec/stdlib/titan/coroutine_native/coroutine_native)
        ;;
    async)
        tree=spec/stdlib/titan
        output=async_tests__main
        roots=(async_tests)
        sources=(spec/stdlib/titan/async_tests/async_tests)
        ;;
    http)
        tree=spec/stdlib/titan
        output=http_native__main
        roots=(http_native)
        sources=(spec/stdlib/titan/http_native/http_native)
        ;;
    net-ssl)
        tree=spec/stdlib/titan
        output=net_ssl_native__main
        roots=(net_ssl_native)
        sources=(spec/stdlib/titan/net_ssl_native/net_ssl_native)
        ;;
    lua-peg)
        tree=spec/stdlib/titan
        output=lua_peg_native__main
        roots=(lua_peg_native)
        sources=(spec/stdlib/titan/lua_peg_native/lua_peg_native)
        ;;
    os-uv)
        tree=spec/stdlib/titan
        output=os_uv_native__main
        roots=(os_uv_native)
        sources=(spec/stdlib/titan/os_uv_native/os_uv_native)
        ;;
    os)
        tree=spec/stdlib/titan
        output=os_native__main
        roots=(os_native)
        sources=(spec/stdlib/titan/os_native/os_native)
        ;;
    uv-tasks)
        tree=spec/stdlib/titan
        output=uv_tasks_native__main
        roots=(uv_tasks_native)
        sources=(spec/stdlib/titan/uv_tasks_native/uv_tasks_native)
        ;;
    io-fs-timer)
        tree=spec/stdlib/titan
        output=io_fs_timer__main
        roots=(io_fs_timer)
        sources=(spec/stdlib/titan/io_fs_timer/io_fs_timer)
        ;;
    *)
        echo "usage: $0 {pure|math|peg|string|url|lua-peg|coroutine|async|http|net-ssl|os|os-uv|uv-tasks|io-fs-timer} [runner-options...]" >&2
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
    if [[ -n $synthetic_parent ]]; then
        rmdir -- "$synthetic_parent" 2>/dev/null || true
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

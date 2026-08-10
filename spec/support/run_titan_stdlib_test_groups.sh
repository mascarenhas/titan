#!/usr/bin/env bash

# Run native Titan standard-library suites directly and validate diagnostics
# that intentionally cross the generated executable's process boundary.

set -euo pipefail

group=${1:-}
SUITE_RUNNER=spec/support/run_titan_stdlib_tests.sh
TASK_DIAGNOSTIC='uncaught error in async Task:'
last_output=

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

run_suite() {
    local name=$1
    shift
    local output
    # Command substitution keeps the executable's stdout/stderr on a pipe.
    # Several parent-stdio tests deliberately distinguish pipes from regular
    # files, so redirecting the child straight to a diagnostic log would
    # change the boundary under test.
    if ! output=$(bash "$SUITE_RUNNER" "$name" "$@" 2>&1); then
        printf '%s
' "$output" >&2
        fail "native Titan suite $name failed"
    fi
    printf '%s
' "$output"
    last_output=$output
}

count_occurrences() {
    local subject=$1
    local needle=$2
    local count
    count=$(printf '%s' "$subject" | grep -oF -- "$needle" | wc -l || true)
    printf '%s' "${count//[[:space:]]/}"
}

require_count() {
    local subject=$1
    local needle=$2
    local expected=$3
    local actual
    actual=$(count_occurrences "$subject" "$needle")
    if [[ $actual != "$expected" ]]; then
        printf '%s\n' "$subject" >&2
        fail "expected $expected occurrences of '$needle', found $actual"
    fi
}

require_contains() {
    local subject=$1
    local needle=$2
    if [[ $subject != *"$needle"* ]]; then
        printf '%s\n' "$subject" >&2
        fail "expected native output to contain '$needle'"
    fi
}

require_absent() {
    local subject=$1
    local needle=$2
    if [[ $subject == *"$needle"* ]]; then
        printf '%s\n' "$subject" >&2
        fail "native output unexpectedly contained '$needle'"
    fi
}

filter_section() {
    local subject=$1
    local filter=$2
    printf '%s\n' "$subject" | awk -v marker="===== TITAN FILTER $filter =====" '
        $0 == marker { active = 1; next }
        active && /^===== TITAN FILTER / { exit }
        active { print }
    '
}

run_library_serial() {
    run_suite coroutine
    require_absent "$last_output" "$TASK_DIAGNOSTIC"
}

run_library_sync() {
    local name
    for name in iter gc lua math peg string; do
        run_suite "$name"
        require_absent "$last_output" "$TASK_DIAGNOSTIC"
    done
}

run_library_uv_fs() {
    run_suite async
    require_count "$last_output" "$TASK_DIAGNOSTIC" 7
    local message
    for message in \
        all-live-logged-failure \
        all-logged-failure \
        combinator-logged-failure \
        any-live-logged-failure \
        join-logged-failure \
        race-logged-failure; do
        require_contains "$last_output" "$message"
    done
    require_absent "$last_output" swallowed-listener-error

    run_suite uv-tasks
    require_count "$last_output" "$TASK_DIAGNOSTIC" 1
    require_contains "$last_output" task-status-boom
    require_contains "$last_output" 'in uv.task_tests.failed_origin'

    run_suite io-fs-timer
    require_absent "$last_output" "$TASK_DIAGNOSTIC"
}

run_http() {
    local filters=(
        test_server_idle_keep_alive_eof_is_clean
        test_server_buffered_empty_lines_eof_is_malformed
        test_server_partial_keep_alive_eof_is_malformed
        test_server_partial_empty_line_eof_is_malformed
        test_plain_http_header_idle_timeout_protocol
        test_https_header_idle_timeout_protocol
    )
    run_suite http --also-each-filter "${filters[@]}"
    local full_run=${last_output%%$'\n===== TITAN FILTER '*}
    require_count "$full_run" "$TASK_DIAGNOSTIC" 14

    local section
    section=$(filter_section "$last_output" "${filters[0]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 0

    section=$(filter_section "$last_output" "${filters[1]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 1
    require_contains "$section" 'HTTP message ended before it was complete'

    section=$(filter_section "$last_output" "${filters[2]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 1
    require_contains "$section" HPE_INVALID_EOF_STATE

    section=$(filter_section "$last_output" "${filters[3]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 1
    require_contains "$section" 'HTTP message ended before it was complete'

    section=$(filter_section "$last_output" "${filters[4]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 1
    require_contains "$section" 'HTTP parse error'

    section=$(filter_section "$last_output" "${filters[5]}")
    require_count "$section" "$TASK_DIAGNOSTIC" 0
}

run_library_net_os() {
    run_suite net-ssl
    require_absent "$last_output" "$TASK_DIAGNOSTIC"

    run_http

    run_suite url
    require_absent "$last_output" "$TASK_DIAGNOSTIC"

    run_suite os
    require_absent "$last_output" "$TASK_DIAGNOSTIC"

    run_suite os-process --each-filter-only \
        test_signal_watcher_validation_delivery_cancellation_and_replacement \
        test_stream_facades_capture_merge_inheritance_options_and_interfaces \
        test_stream_facade_close_wakes_pending_reader
    require_absent "$last_output" "$TASK_DIAGNOSTIC"

    run_suite uv-runtime --filter=test_runtime_shutdown_closes_native_handles_but_not_files
    require_absent "$last_output" "$TASK_DIAGNOSTIC"
}

case "$group" in
    library-serial)
        run_library_serial
        ;;
    library-uv-fs)
        run_library_uv_fs
        ;;
    library-net-os)
        run_library_net_os
        ;;
    library-peg-string)
        run_library_sync
        ;;
    all)
        run_library_serial
        run_library_sync
        run_library_uv_fs
        run_library_net_os
        ;;
    *)
        echo "usage: $0 {all|library-serial|library-uv-fs|library-net-os|library-peg-string}" >&2
        exit 2
        ;;
esac

#!/usr/bin/env bash

# Compiler specs reuse checkout-root artifact names, so local parallel runs
# need private copies of the complete prepared checkout.  Keep this launcher
# usable by the Bash 3.2 shipped with macOS: in particular, do not rely on
# wait -n, associative arrays, mapfile, or GNU-only process helpers.

set -u

jobs=${TITAN_ROCK_TEST_JOBS:-4}
if [[ ! $jobs =~ ^[1-4]$ ]]; then
    echo "TITAN_ROCK_TEST_JOBS must be an integer from 1 through 4" >&2
    exit 2
fi

workspace=$(pwd -P) || exit 1
if [[ ! -f $workspace/Makefile ||
      ! -f $workspace/spec/support/ci_test_groups.sh ]]; then
    echo "parallel compiler tests must run from the Titan checkout root" >&2
    exit 2
fi

resolve_executable() {
    local candidate=$1
    local resolved=
    local directory=
    local basename=

    case "$candidate" in
        */*)
            case "$candidate" in
                /*) ;;
                *) candidate=$workspace/$candidate ;;
            esac
            directory=${candidate%/*}
            basename=${candidate##*/}
            resolved=$(cd "$directory" 2>/dev/null &&
                printf '%s/%s\n' "$(pwd -P)" "$basename") || return 1
            ;;
        *)
            resolved=$(command -v "$candidate" 2>/dev/null) || return 1
            case "$resolved" in
                /*) ;;
                */*)
                    directory=${resolved%/*}
                    basename=${resolved##*/}
                    resolved=$(cd "$directory" 2>/dev/null &&
                        printf '%s/%s\n' "$(pwd -P)" "$basename") ||
                        return 1
                    ;;
                *) return 1 ;;
            esac
            ;;
    esac

    [[ -f $resolved && -x $resolved ]] || return 1
    printf '%s\n' "$resolved"
}

if [[ -n ${BUSTED:-} ]]; then
    busted_candidate=$BUSTED
elif [[ -n ${PREFIX:-} && -x $PREFIX/bin/busted ]]; then
    busted_candidate=$PREFIX/bin/busted
elif [[ -x $workspace/.lua/bin/busted ]]; then
    busted_candidate=$workspace/.lua/bin/busted
elif [[ -x $workspace/lua_modules/bin/busted ]]; then
    busted_candidate=$workspace/lua_modules/bin/busted
else
    busted_candidate=busted
fi
if ! busted=$(resolve_executable "$busted_candidate"); then
    echo "parallel compiler tests require an executable Busted command" >&2
    exit 2
fi

temporary_base=${TMPDIR:-/tmp}
if ! temporary_base=$(cd "$temporary_base" 2>/dev/null && pwd -P); then
    echo "parallel compiler tests require an existing temporary directory" >&2
    exit 2
fi
case "$temporary_base" in
    "$workspace" | "$workspace"/*)
        echo "parallel compiler test workers must live outside the checkout" >&2
        exit 2
        ;;
esac

worker_root=$(mktemp -d \
    "$temporary_base/titan-rock-compiler-workers.XXXXXX") || exit 1
archive=$worker_root/prepared-checkout.tar
completion_fifo=$worker_root/completions
worker_pids=()
monitor_pids=()
cleanup_started=0
pending_signal=0

terminate_worker_groups() {
    local shard=
    local pid=
    local attempt=
    local running=

    for shard in 1 2 3 4; do
        for pid in "${worker_pids[$shard]-}" \
            "${monitor_pids[$shard]-}"; do
            if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                kill -TERM -- "-$pid" 2>/dev/null || true
            fi
        done
    done

    # Give compiler children a short opportunity to remove their own files,
    # then make signal cleanup bounded even if a child ignores TERM.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        running=0
        for shard in 1 2 3 4; do
            for pid in "${worker_pids[$shard]-}" \
                "${monitor_pids[$shard]-}"; do
                if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                    running=1
                    break 2
                fi
            done
        done
        if (( running == 0 )); then break; fi
        sleep 0.1
    done

    for shard in 1 2 3 4; do
        for pid in "${worker_pids[$shard]-}" \
            "${monitor_pids[$shard]-}"; do
            if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                kill -KILL -- "-$pid" 2>/dev/null || true
            fi
        done
    done
    for shard in 1 2 3 4; do
        for pid in "${worker_pids[$shard]-}" \
            "${monitor_pids[$shard]-}"; do
            if [[ -n $pid ]]; then wait "$pid" 2>/dev/null || true; fi
        done
        unset 'worker_pids[$shard]'
        unset 'monitor_pids[$shard]'
    done
}

cleanup() {
    if (( cleanup_started != 0 )); then return; fi
    cleanup_started=1
    trap - EXIT
    trap '' HUP INT TERM
    terminate_worker_groups
    { exec 9>&-; } 2>/dev/null || true
    case "$worker_root" in
        "$temporary_base"/titan-rock-compiler-workers.*)
            rm -rf -- "$worker_root"
            ;;
        *)
            echo "refusing to remove unexpected worker path: $worker_root" >&2
            ;;
    esac
}

handle_signal() {
    local status=$1
    cleanup
    exit "$status"
}

defer_signal() {
    local status=$1
    if (( pending_signal == 0 )); then pending_signal=$status; fi
}

install_signal_handlers() {
    trap 'handle_signal 129' HUP
    trap 'handle_signal 130' INT
    trap 'handle_signal 143' TERM
}

defer_launch_signals() {
    trap 'defer_signal 129' HUP
    trap 'defer_signal 130' INT
    trap 'defer_signal 143' TERM
}

trap cleanup EXIT
install_signal_handlers

echo "Snapshotting the prepared checkout for four isolated compiler shards"
if ! (
    cd "$workspace" || exit 1
    tar --exclude='./.git' --exclude='./.git/*' \
        --exclude='./libbacktrace/.git' \
        --exclude='./libbacktrace/.git/*' \
        --exclude='./.lua' --exclude='./.lua/*' \
        -cf "$archive" .
); then
    echo "could not snapshot the prepared checkout" >&2
    exit 1
fi

for shard in 1 2 3 4; do
    worker=$worker_root/work-$shard
    if ! mkdir -p "$worker" "$worker_root/tmp-$shard/ccache" ||
       ! tar -xf "$archive" -C "$worker"; then
        echo "could not prepare isolated compiler test worker $shard" >&2
        exit 1
    fi
done

if ! mkfifo "$completion_fifo"; then
    echo "could not create compiler worker completion channel" >&2
    exit 1
fi
exec 9<> "$completion_fifo"

tag_output() {
    local shard=$1
    local line=
    while IFS= read -r line || [[ -n $line ]]; do
        printf '[compiler shard %s] %s\n' "$shard" "$line"
    done
}

run_worker() {
    local shard=$1
    local worker=$worker_root/work-$shard
    local log=$worker_root/shard-$shard.log
    local status_file=$worker_root/shard-$shard.status
    local started=$SECONDS
    local status=0
    local status_write=0
    local -a pipeline_status

    printf '===== starting compiler shard %s =====\n' "$shard"
    (
        cd "$worker" || exit 1
        rm -f luacov.stats.out luacov.report.out || exit 1
        unset LUACOV_CONFIG
        BUSTED="$busted" \
            CCACHE_TEMPDIR="$worker_root/tmp-$shard/ccache" \
            MAKEFLAGS=-j1 \
            TITAN_JOBS=1 \
            TMPDIR="$worker_root/tmp-$shard" \
            bash spec/support/ci_test_groups.sh \
                "compiler-uncovered-shard-$shard"
    ) 2>&1 | tag_output "$shard" | tee "$log"
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if (( pipeline_status[1] != 0 || pipeline_status[2] != 0 )); then
        if (( status == 0 )); then status=1; fi
    fi
    if [[ -e $worker/luacov.stats.out ||
          -e $worker/luacov.report.out ]]; then
        echo "compiler shard $shard unexpectedly produced LuaCov output" >&2
        if (( status == 0 )); then status=1; fi
    fi

    if ! printf '%s\n' "$status" > "$status_file"; then
        status=1
        status_write=1
    fi
    printf '===== finished compiler shard %s: status=%s, %ss =====\n' \
        "$shard" "$status" "$((SECONDS - started))"
    if (( status_write != 0 )); then
        echo "could not record compiler shard $shard status" >&2
    fi
    printf '%s worker %s\n' "$shard" "$status" >&9 || exit 1
    return "$status"
}

# A worker normally reports its status itself, but SIGKILL and other abrupt
# exits can bypass that write.  Keep a tiny watcher in a different process
# group so the parent still receives a completion within one polling tick.
# The direct and watched notifications are redundant by design; the scheduler
# ignores whichever duplicate arrives after it has reaped the worker.
monitor_worker() {
    local shard=$1
    local worker_pid=$2
    while kill -0 "$worker_pid" 2>/dev/null; do sleep 0.1; done
    printf '%s monitor\n' "$shard" >&9
}

terminate_one_worker_group() {
    local pid=$1
    local attempt=
    if kill -0 -- "-$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || true
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 -- "-$pid" 2>/dev/null; then return; fi
        sleep 0.1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
}

launch_worker() {
    local shard=$1
    local worker_pid=
    local monitor_pid=
    local deferred_status=

    # Bash has no portable signal-mask builtin.  Deferred handlers make the
    # two background launches and both $! registrations atomic with respect to
    # cleanup: a signal in either narrow window is serviced only after every
    # process group that exists has been recorded.
    defer_launch_signals
    run_worker "$shard" &
    worker_pid=$!
    worker_pids[$shard]=$worker_pid
    monitor_worker "$shard" "$worker_pid" &
    monitor_pid=$!
    monitor_pids[$shard]=$monitor_pid
    install_signal_handlers

    if (( pending_signal != 0 )); then
        deferred_status=$pending_signal
        pending_signal=0
        handle_signal "$deferred_status"
    fi
}

stop_monitor() {
    local shard=$1
    local monitor_pid=${monitor_pids[$shard]-}
    if [[ -z $monitor_pid ]]; then return; fi
    if kill -0 -- "-$monitor_pid" 2>/dev/null; then
        kill -TERM -- "-$monitor_pid" 2>/dev/null || true
    fi
    wait "$monitor_pid" 2>/dev/null || true
    unset 'monitor_pids[$shard]'
}

# Monitor mode gives every background worker its own process group.  This is
# available in Bash 3.2 and lets the signal traps terminate a worker's Busted,
# compiler, Make, and native-compiler descendants as one bounded unit.
set -m

launched=0
active=0
completed=0
scheduler_status=0
while (( completed < 4 )); do
    while (( launched < 4 && active < jobs )); do
        shard=$((launched + 1))
        launch_worker "$shard"
        launched=$shard
        active=$((active + 1))
    done

    completed_shard=
    completed_source=
    completed_status=
    completed_extra=
    if ! IFS=' ' read -r completed_shard completed_source \
        completed_status completed_extra <&9; then
        echo "could not read compiler worker completion" >&2
        scheduler_status=1
        break
    fi
    if [[ ! $completed_shard =~ ^[1-4]$ ||
          ! $completed_source =~ ^(worker|monitor)$ ||
          -n $completed_extra ]]; then
        echo "invalid compiler worker completion: " \
            "$completed_shard $completed_source $completed_status " \
            "$completed_extra" >&2
        scheduler_status=1
        break
    fi
    if [[ $completed_source == worker &&
          ! $completed_status =~ ^[0-9]+$ ]] ||
       [[ $completed_source == monitor && -n $completed_status ]]; then
        echo "invalid compiler worker completion: " \
            "$completed_shard $completed_source $completed_status" >&2
        scheduler_status=1
        break
    fi

    # Direct completion and the independent monitor can both leave a record.
    # A stale duplicate is harmless and must not consume another active slot.
    if [[ -z ${worker_pids[$completed_shard]-} ]]; then continue; fi

    pid=${worker_pids[$completed_shard]}
    if [[ $completed_source == monitor ]]; then
        # The wrapper can die while compiler or logging descendants remain in
        # its process group.  Retire that group before freeing/refilling the
        # slot so no orphan can retain the FIFO, log pipe, or worker checkout.
        terminate_one_worker_group "$pid"
    fi
    wait_status=0
    wait "$pid" || wait_status=$?
    unset 'worker_pids[$completed_shard]'
    stop_monitor "$completed_shard"
    active=$((active - 1))
    completed=$((completed + 1))
    if [[ $completed_source == monitor ]]; then
        echo "compiler shard $completed_shard exited before its completion" \
            "notification: status=$wait_status" >&2
        if ! printf '%s\n' "$wait_status" > \
            "$worker_root/shard-$completed_shard.status"; then
            echo "could not record compiler shard $completed_shard status" >&2
            scheduler_status=1
        fi
    elif (( wait_status != completed_status )); then
        echo "compiler shard $completed_shard status disagreement: " \
            "reported=$completed_status wait=$wait_status" >&2
        scheduler_status=1
    fi
done

status=$scheduler_status
for shard in 1 2 3 4; do
    log=$worker_root/shard-$shard.log
    status_file=$worker_root/shard-$shard.status
    if [[ ! -s $log ]]; then
        echo "compiler shard $shard produced no readable tagged log" >&2
        status=1
    fi
    shard_status=
    if [[ -f $status_file ]]; then
        read -r shard_status < "$status_file" || shard_status=
    fi
    if [[ ! $shard_status =~ ^[0-9]+$ || $shard_status != 0 ]]; then
        echo "compiler shard $shard failed: ${shard_status:-missing status}" >&2
        status=1
    fi
done

if (( status != 0 )); then exit 1; fi
echo "All four compiler shards passed"

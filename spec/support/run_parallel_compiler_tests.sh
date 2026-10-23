#!/usr/bin/env bash

# Compiler specs reuse checkout-root artifact names, so local parallel runs
# need private copies of the complete prepared checkout.  Keep this launcher
# usable by the Bash 3.2 shipped with macOS: in particular, do not rely on
# wait -n, associative arrays, mapfile, or GNU-only process helpers.

set -u

jobs=${TITAN_ROCK_TEST_JOBS:-4}
windows=0
if [[ ${MSYSTEM:-} == CLANG64 ]]; then
    windows=1
    jobs=${TITAN_ROCK_TEST_JOBS:-3}
fi
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

exclusive_shard=
if (( windows != 0 )); then
    # The real parallel-compilation fixtures choose their own native bound.
    # Run their owning shard alone instead of silently multiplying that bound
    # by another active shard. Keep its ordinary manifest membership intact.
    while read -r shard test_file rest; do
        if [[ $test_file == spec/coder/parallel_compilation_spec.lua ]]; then
            if [[ -n $exclusive_shard || ! $shard =~ ^[1-4]$ ]]; then
                echo "invalid parallel-compilation shard membership" >&2
                exit 2
            fi
            exclusive_shard=$shard
        fi
    done < "$workspace/spec/support/ci_compiler_test_groups.txt"
    [[ -n $exclusive_shard ]] || {
        echo "parallel-compilation spec is missing from the shard manifest" >&2
        exit 2
    }
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

if (( windows != 0 )); then
    prefix_unix=$(cygpath -u "${PREFIX:?selected Lua SDK prefix is required}") || exit 2
    export PREFIX=$(cygpath -m "$prefix_unix")
    export PATH="$prefix_unix/bin:$PATH"
    native_lua=$prefix_unix/bin/lua.exe
    busted_scripts=("$prefix_unix"/lib/luarocks/rocks-5.5/busted/*/bin/busted)
    native_busted=${busted_scripts[0]}
    [[ -x $native_lua && -f $native_busted ]] || {
        echo "Windows compiler tests require the selected Lua and installed Busted script" >&2
        exit 2
    }
    supervisor_candidate=$(cygpath -u \
        "${TITAN_ROCK_TEST_SUPERVISOR:?Make must select the native test supervisor}") || exit 2
    supervisor=$(resolve_executable "$supervisor_candidate") || {
        echo "Windows compiler tests require the prepared native test supervisor" >&2
        exit 2
    }
    native_bash=$(resolve_executable "$BASH") || exit 2
    if [[ -f $native_bash.exe ]]; then native_bash=$native_bash.exe; fi
    worker_timeout=${TITAN_ROCK_TEST_TIMEOUT_MS:-28800000}
    [[ $worker_timeout =~ ^[1-9][0-9]*$ ]] || {
        echo "TITAN_ROCK_TEST_TIMEOUT_MS must be a positive integer" >&2
        exit 2
    }
elif [[ -n ${BUSTED:-} ]]; then
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
if (( windows == 0 )) && ! busted=$(resolve_executable "$busted_candidate"); then
    echo "parallel compiler tests require an executable Busted command" >&2
    exit 2
fi

temporary_base=${TMPDIR:-/tmp}
if (( windows != 0 )); then
    # Native fixtures add their own directories and reserved sibling names.
    # Keep this base short instead of inheriting a deeply nested build TEMP.
    temporary_base=/tmp
fi
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

if (( windows != 0 )); then
    # Keep the selected SDK's ordinary package.path/cpath. Loading a checkout
    # compiler here would change runtime selection in fresh fixture children.
    cat > "$worker_root/installed-origins.lua" <<'LUA'
local prefix = assert(os.getenv("PREFIX"))
local driver = require("titan-compiler.driver")
local filesystem = require("titan-compiler.io").new_sync()
local path = require("titan-compiler.path")
for _, item in ipairs({
    {"driver", driver.defaultloader, "driver.lua"},
    {"checker", require("titan-compiler.checker.entry").check, "checker/entry.lua"},
    {"ffiheaders", require("titan-compiler.ffiheaders").quote_header, "ffiheaders.lua"},
}) do
    local origin = assert(debug.getinfo(item[2], "S").source)
    assert(origin:sub(1, 1) == "@", origin)
    local actual = assert(filesystem:realpath(origin:sub(2)))
    local selected = assert(filesystem:realpath(path.join(prefix, "share", "lua", "5.5", "titan-compiler", item[3])))
    local a, b = assert(filesystem:stat(actual)), assert(filesystem:stat(selected))
    assert(a.kind == "file" and b.kind == "file")
    assert(path.normalize(actual):lower() == path.normalize(selected):lower(),
        "compiler origin differs from the selected SDK: " .. origin)
    print("compiler worker installed " .. item[1] .. "=" .. actual)
end
print("compiler worker profile=" .. driver.BUILD_PROFILE)
LUA
    cat > "$worker_root/busted.lua" <<'LUA'
-- Keep the native loop alive across Busted's per-file module isolation.
require "luv"
io.stdout:setvbuf("no"); io.stderr:setvbuf("no")
local script = assert(table.remove(arg, 1))
arg[0] = script
dofile(script)
-- The stock runner returns only after a successful non-standalone run. A
-- missing marker also catches native exit codes truncated by a Bash wait.
local file = assert(io.open(assert(os.getenv("TITAN_ROCK_TEST_BUSTED_COMPLETION")), "wb"))
assert(file:write("passed\n")); assert(file:close())
LUA
    cat > "$worker_root/busted.sh" <<'SH'
#!/usr/bin/env bash
set -u
marker=${TITAN_ROCK_TEST_BUSTED_COMPLETION:?}
rm -f "$marker" || exit 1
# Inspect installed origins in a separate process, so Busted starts without
# compiler modules or native metadata images retained by this preflight.
"$TITAN_ROCK_TEST_LUA" "$TITAN_ROCK_TEST_ORIGIN_CHECK" || exit 1
"$TITAN_ROCK_TEST_LUA" "$TITAN_ROCK_TEST_BUSTED_LAUNCHER" \
    "$TITAN_ROCK_TEST_BUSTED_SCRIPT" "$@"
status=$?
if (( status == 0 )) && [[ $(cat "$marker" 2>/dev/null) != passed ]]; then
    echo 'native Busted exited without its success marker' >&2
    status=1
fi
exit "$status"
SH
    chmod +x "$worker_root/busted.sh" || exit 1
    busted=$worker_root/busted.sh
    export TITAN_ROCK_TEST_LUA=$(cygpath -m "$native_lua")
    export TITAN_ROCK_TEST_BUSTED_LAUNCHER=$(cygpath -m "$worker_root/busted.lua")
    export TITAN_ROCK_TEST_BUSTED_SCRIPT=$(cygpath -m "$native_busted")
    export TITAN_ROCK_TEST_ORIGIN_CHECK=$(cygpath -m "$worker_root/installed-origins.lua")
    # These values already have the spelling expected by their consumer. In
    # particular, semicolon Titan/Lua search lists are not MSYS path lists.
    export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+$MSYS2_ENV_CONV_EXCL;}PREFIX;TMP;TEMP;TITAN_ROCKS_ROOT;TITAN_PATH;LUA_PATH;LUA_CPATH;BUSTED;TITAN_ROCK_TEST_LUA;TITAN_ROCK_TEST_BUSTED_LAUNCHER;TITAN_ROCK_TEST_BUSTED_SCRIPT;TITAN_ROCK_TEST_ORIGIN_CHECK;TITAN_ROCK_TEST_BUSTED_COMPLETION"
fi

echo "Snapshotting the prepared checkout for four isolated compiler shards"
# Workers use the selected SDK read-only at its own path, so a prefix inside
# the checkout is never copied into the worker snapshots.
prefix_excludes=()
if prefix_physical=$(cd "${PREFIX:-/nonexistent}" 2>/dev/null && pwd -P); then
    case "$prefix_physical" in
        "$workspace"/?*)
            prefix_relative=${prefix_physical#"$workspace"/}
            prefix_excludes=(--exclude="./$prefix_relative"
                             --exclude="./$prefix_relative/*")
            ;;
    esac
fi
if ! (
    cd "$workspace" || exit 1
    tar --exclude='./.git' --exclude='./.git/*' \
        --exclude='./libbacktrace/.git' \
        --exclude='./libbacktrace/.git/*' \
        --exclude='./.lua' --exclude='./.lua/*' \
        ${prefix_excludes[@]+"${prefix_excludes[@]}"} \
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
        export BUSTED="$busted" \
            CCACHE_TEMPDIR="$worker_root/tmp-$shard/ccache" \
            MAKEFLAGS=-j1 \
            TITAN_JOBS=1 \
            TMPDIR="$worker_root/tmp-$shard"
        if (( windows != 0 )); then
            export TMP=$(cygpath -m "$TMPDIR") TEMP=$(cygpath -m "$TMPDIR")
            export TITAN_ROCK_TEST_BUSTED_COMPLETION=$(cygpath -m "$worker_root/shard-$shard.busted-passed")
            # Native children inherit a private Job Object. The supervisor
            # reaps that tree before returning, including after normal exit;
            # killing this MSYS group closes its KILL_ON_JOB_CLOSE handle.
            "$supervisor" "$worker_timeout" "$(cygpath -m "$native_bash")" \
                "$(cygpath -m "$worker/spec/support/ci_test_groups.sh")" \
                "compiler-uncovered-shard-$shard"
        else
            bash spec/support/ci_test_groups.sh \
                "compiler-uncovered-shard-$shard"
        fi
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
# Unix launches shards in manifest order. On Windows the exclusive shard runs
# first and alone; the other three then share the worker slots instead of
# each queueing behind it.
launch_order=(1 2 3 4)
if (( windows != 0 )); then
    launch_order=("$exclusive_shard")
    for shard in 1 2 3 4; do
        if [[ $shard != "$exclusive_shard" ]]; then launch_order+=("$shard"); fi
    done
fi
while (( completed < 4 )); do
    while (( launched < 4 && active < jobs )); do
        shard=${launch_order[$launched]}
        if (( windows != 0 && active != 0 )) &&
           [[ $shard == "$exclusive_shard" ||
              -n ${worker_pids[$exclusive_shard]-} ]]; then
            break
        fi
        launch_worker "$shard"
        launched=$((launched + 1))
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

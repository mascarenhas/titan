#!/usr/bin/env bash

# Implementation notes: doc/implementation/test-runner.md#busted-partitions
# Run every classified Busted spec file once, per file, across private copies
# of the complete prepared checkout. Compiler and runtime/packaging specs reuse
# checkout-root artifact names, so each worker owns a checkout copy, TMPDIR,
# ccache scratch, and log. spec/support/compiler_test_groups.lua plans the
# ordinary files with deterministic LPT for TITAN_ROCK_TEST_JOBS workers and
# names the genuinely exclusive files, which run alone after the pool.
#
# Unix workers are targets of one ephemeral GNU Make work graph that shares a
# single job pool with the optional native aggregate build. Windows keeps its
# native Job Object supervisor and FIFO scheduler. Keep this launcher usable
# by the Bash 3.2 shipped with macOS: do not rely on wait -n, associative
# arrays, mapfile, or GNU-only helpers.

set -u

windows=0
if [[ ${MSYSTEM:-} == CLANG64 ]]; then
    windows=1
fi
build_native=${TITAN_ROCK_TEST_BUILD_NATIVE:-0}
if (( windows != 0 )); then
    # Windows builds and runs its native aggregate before the Busted phase.
    build_native=0
fi
native_status_file=${TITAN_ROCK_TEST_NATIVE_STATUS:-}
# Four workers fill the default four-slot pool. When the native build
# shares that pool, a fourth worker would wait for a slot while the build
# holds one; three workers finished that phase sooner in measurement.
default_jobs=4
if (( build_native != 0 )); then
    default_jobs=3
fi
jobs=${TITAN_ROCK_TEST_JOBS:-$default_jobs}
if [[ ! $jobs =~ ^[1-9][0-9]*$ || ${#jobs} -gt 9 ]]; then
    echo "TITAN_ROCK_TEST_JOBS must be a positive integer" >&2
    exit 2
fi
# Without TITAN_JOBS (the Makefile omits it on GNU Make before 4.2, which
# cannot show an explicit -j1), a seeded pool has one slot per worker and one
# for the native build, so the workers never wait for each other.
pool_jobs=${TITAN_JOBS:-$((jobs + (build_native != 0 ? 1 : 0)))}
if [[ ! $pool_jobs =~ ^[1-9][0-9]*$ || ${#pool_jobs} -gt 9 ]]; then
    echo "TITAN_JOBS must be a positive integer" >&2
    exit 2
fi

workspace=$(pwd -P) || exit 1
if [[ ! -f $workspace/Makefile ||
      ! -f $workspace/spec/support/compiler_test_groups.lua ||
      ! -f $workspace/spec/support/ci_compiler_test_groups.txt ]]; then
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
    lua_cmd=$native_lua
else
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
    lua_cmd=
    for lua_candidate in "${LUA:-}" "${PREFIX:+$PREFIX/bin/lua}" \
        "$workspace/.lua/bin/lua" "${busted%/*}/lua" lua; do
        [[ -n $lua_candidate ]] || continue
        if lua_cmd=$(resolve_executable "$lua_candidate"); then break; fi
        lua_cmd=
    done
    if [[ -z $lua_cmd ]]; then
        echo "parallel compiler tests require a Lua interpreter for partitioning" >&2
        exit 2
    fi
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
all_shards=()
ordinary_shards=()
exclusive_shard=
graph_pid=
cleanup_started=0
pending_signal=0

collect_recorded_worker_pids() {
    local pid_file=
    local recorded_pid=
    for pid_file in "$worker_root"/worker-*.pid; do
        [[ -f $pid_file ]] || continue
        read -r recorded_pid < "$pid_file" 2>/dev/null || recorded_pid=
        if [[ $recorded_pid =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$recorded_pid"
        fi
    done
}

# Terminate every process group this launcher started: the Make work graph
# (its recipe shells and the native build), each shard wrapper, and each
# shard's own Busted group recorded by the Unix wrappers.
terminate_worker_groups() {
    local shard=
    local pid=
    local attempt=
    local running=
    local pids_to_kill=()
    local recorded=

    if [[ -n $graph_pid ]]; then pids_to_kill+=("$graph_pid"); fi
    for shard in "${all_shards[@]+"${all_shards[@]}"}"; do
        for pid in "${worker_pids[$shard]-}" "${monitor_pids[$shard]-}"; do
            if [[ -n $pid ]]; then pids_to_kill+=("$pid"); fi
        done
    done
    while IFS= read -r recorded; do
        [[ -n $recorded ]] && pids_to_kill+=("$recorded")
    done < <(collect_recorded_worker_pids)

    for pid in "${pids_to_kill[@]+"${pids_to_kill[@]}"}"; do
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -TERM -- "-$pid" 2>/dev/null || true
        fi
    done

    # Give compiler children a short opportunity to remove their own files,
    # then make signal cleanup bounded even if a child ignores TERM.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        running=0
        for pid in "${pids_to_kill[@]+"${pids_to_kill[@]}"}"; do
            if kill -0 -- "-$pid" 2>/dev/null; then
                running=1
                break
            fi
        done
        if (( running == 0 )); then break; fi
        sleep 0.1
    done

    for pid in "${pids_to_kill[@]+"${pids_to_kill[@]}"}"; do
        if kill -0 -- "-$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        fi
    done
    if [[ -n $graph_pid ]]; then wait "$graph_pid" 2>/dev/null || true; fi
    graph_pid=
    for shard in "${all_shards[@]+"${all_shards[@]}"}"; do
        for pid in "${worker_pids[$shard]-}" "${monitor_pids[$shard]-}"; do
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
    if [[ -n $native_status_file ]]; then rm -f -- "$native_status_file"; fi
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

# Record a launched background process, then deliver any signal that arrived
# while the launch was in progress.
finish_launch() {
    local deferred_status=
    install_signal_handlers
    if (( pending_signal != 0 )); then
        deferred_status=$pending_signal
        pending_signal=0
        handle_signal "$deferred_status"
    fi
}

trap cleanup EXIT
install_signal_handlers

"$lua_cmd" -E "$workspace/spec/support/compiler_test_groups.lua" \
    local-plan "$jobs" "$worker_root" || exit 2
effective_jobs=0
exclusive_count=0
while IFS='=' read -r key val; do
    case "$key" in
        effective_jobs) effective_jobs=$val ;;
        exclusive_count) exclusive_count=$val ;;
    esac
done < "$worker_root/plan.summary"
for ((shard = 1; shard <= effective_jobs; shard++)); do
    ordinary_shards+=("$shard")
    all_shards+=("$shard")
done
if (( exclusive_count > 0 )); then
    exclusive_shard=$((effective_jobs + 1))
    mv "$worker_root/files-exclusive.txt" \
        "$worker_root/files-$exclusive_shard.txt" || exit 1
    all_shards+=("$exclusive_shard")
fi
if (( ${#all_shards[@]} == 0 )); then
    echo "the compiler test plan selected no spec files" >&2
    exit 2
fi

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
if [[ ${TITAN_ROCK_TEST_ORIGIN_CHECKED:-0} != 1 ]]; then
    "$TITAN_ROCK_TEST_LUA" "$TITAN_ROCK_TEST_ORIGIN_CHECK" || exit 1
fi
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
    export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+$MSYS2_ENV_CONV_EXCL;}PREFIX;TMP;TEMP;TITAN_ROCKS_ROOT;TITAN_PATH;LUA_PATH;LUA_CPATH;BUSTED;TITAN_ROCK_TEST_LUA;TITAN_ROCK_TEST_BUSTED_LAUNCHER;TITAN_ROCK_TEST_BUSTED_SCRIPT;TITAN_ROCK_TEST_ORIGIN_CHECK;TITAN_ROCK_TEST_BUSTED_COMPLETION;TITAN_SOURCE_GIT_ROOT"
fi

echo "Snapshotting the prepared checkout for ${#all_shards[@]} isolated compiler shards"
# Workers use the selected SDK read-only at its own path, so a prefix inside
# the checkout need not be copied into the worker snapshots. Tar reads an
# exclusion as a pattern; copy a prefix whose name contains pattern syntax
# rather than risk omitting some other checkout path.
prefix_excludes=()
if prefix_physical=$(cd "${PREFIX:-/nonexistent}" 2>/dev/null && pwd -P); then
    case "$prefix_physical" in
        "$workspace"/?*)
            prefix_relative=${prefix_physical#"$workspace"/}
            case "$prefix_relative" in
                *'*'* | *'?'* | *'['* | *'\'*) ;;
                *)
                    prefix_excludes=(--exclude="./$prefix_relative"
                                     --exclude="./$prefix_relative/*")
                    ;;
            esac
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

for shard in "${all_shards[@]}"; do
    worker=$worker_root/work-$shard
    if ! mkdir -p "$worker" "$worker_root/tmp-$shard/ccache" ||
       ! tar -xf "$archive" -C "$worker"; then
        echo "could not prepare isolated compiler test worker $shard" >&2
        exit 1
    fi
done
rm -f "$archive"

# Each shard runs its planned files one Busted process at a time, records one
# PASS/FAIL row per file, and keeps going after a failed file. The exclusive
# files run alone and set their own compiler and Make caps, so their shard
# drops the ordinary workers' nested -j1 policy: titanc reads an inherited
# -j1 as a serial Make job policy.
for shard in "${all_shards[@]}"; do
    shard_job_policy=
    if [[ $shard == "$exclusive_shard" ]]; then
        shard_job_policy='unset MAKEFLAGS MFLAGS MAKELEVEL TITAN_JOBS'
    fi
    cat > "$worker_root/execute-shard-$shard.sh" <<SH
#!/usr/bin/env bash
set -u
shard=$shard
windows=$windows
files_list='$worker_root/files-$shard.txt'
files_summary='$worker_root/shard-$shard.files'

rm -f luacov.stats.out luacov.report.out "\$files_summary" || exit 1
unset LUACOV_CONFIG
export TITAN_PROBE_CACHE_DISABLE=1
$shard_job_policy

if (( windows != 0 )); then
    "\$TITAN_ROCK_TEST_LUA" "\$TITAN_ROCK_TEST_ORIGIN_CHECK" || exit 1
    export TITAN_ROCK_TEST_ORIGIN_CHECKED=1
fi

file_count=0
while IFS= read -r test_file || [[ -n \$test_file ]]; do
    [[ -n \$test_file ]] && file_count=\$((file_count + 1))
done < "\$files_list"
echo "Running \$file_count compiler/runtime spec files in shard \$shard without LuaCov"

shard_status=0
while IFS= read -r test_file || [[ -n \$test_file ]]; do
    [[ -n \$test_file ]] || continue
    file_started=\$SECONDS
    file_status=0
    '$busted' -o gtest -v "\$test_file" < /dev/null || file_status=\$?
    file_elapsed=\$((SECONDS - file_started))
    if (( file_status != 0 )); then
        shard_status=1
        printf 'FAIL\t%s\t%s\t%s\t%s\n' "\$shard" "\$test_file" "\$file_status" "\$file_elapsed" >> "\$files_summary"
        printf '===== failed spec file %s in compiler shard %s: status=%s, %ss =====\n' \\
            "\$test_file" "\$shard" "\$file_status" "\$file_elapsed"
    else
        printf 'PASS\t%s\t%s\t0\t%s\n' "\$shard" "\$test_file" "\$file_elapsed" >> "\$files_summary"
    fi
    # The next file starts from the prepared checkout's root artifact state.
    rm -f -- *.c *.o *.so *.a *.dll *.exe *.ffi.h *.titan.h *.priv.h *.parts test 2>/dev/null || true
    rm -rf -- *.dSYM ./test_runner_* 2>/dev/null || true
done < "\$files_list"
exit "\$shard_status"
SH
    chmod +x "$worker_root/execute-shard-$shard.sh" || exit 1
done

tag_output() {
    local shard=$1
    local line=
    while IFS= read -r line || [[ -n $line ]]; do
        printf '[compiler shard %s] %s\n' "$shard" "$line"
    done
}

# Run one shard in its private checkout and record its status. Nested
# compiler and Make work inside an ordinary Busted worker stays at one job;
# the exclusive shard's execute script clears that policy.
run_worker_core() {
    local shard=$1
    local emit_fifo=${2:-0}
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
        export BUSTED="$busted" \
            CCACHE_TEMPDIR="$worker_root/tmp-$shard/ccache" \
            MAKEFLAGS=-j1 \
            TITAN_JOBS=1 \
            TITAN_SOURCE_GIT_ROOT="$workspace" \
            TMPDIR="$worker_root/tmp-$shard"
        if (( windows != 0 )); then
            export TMP=$(cygpath -m "$TMPDIR") TEMP=$(cygpath -m "$TMPDIR")
            export TITAN_ROCK_TEST_BUSTED_COMPLETION=$(cygpath -m "$worker_root/shard-$shard.busted-passed")
            "$supervisor" "$worker_timeout" "$(cygpath -m "$native_bash")" \
                "$(cygpath -m "$worker_root/execute-shard-$shard.sh")"
        else
            bash "$worker_root/execute-shard-$shard.sh"
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
    if (( emit_fifo != 0 )); then
        printf '%s worker %s\n' "$shard" "$status" >&9 || exit 1
    fi
    return "$status"
}

set -m
scheduler_status=0

if (( windows == 0 )); then
    # Join an inherited usable jobserver; otherwise keep an explicit -j word
    # (including -j1 and unlimited -j); otherwise seed TITAN_JOBS slots. This
    # mirrors the Makefile's graph-entry policy, so Busted workers and the
    # native build share one pool instead of each receiving their own.
    jobserver_usable() {
        local auth=$1
        local r_fd=
        local w_fd=
        case "$auth" in
            fifo:*)
                [[ -p ${auth#fifo:} && -r ${auth#fifo:} && -w ${auth#fifo:} ]]
                ;;
            *,*)
                r_fd=${auth%%,*}
                w_fd=${auth#*,}
                [[ $r_fd =~ ^[0-9]+$ && $w_fd =~ ^[0-9]+$ ]] || return 1
                { true <&"$r_fd" && true >&"$w_fd"; } 2>/dev/null
                ;;
            *)
                return 1
                ;;
        esac
    }
    pool_args=("-j$pool_jobs")
    pool_auth=
    pool_explicit=
    set -f
    # shellcheck disable=SC2086
    set -- ${MAKEFLAGS:-}
    set +f
    case "${1-}" in
        -* | *=*) ;;
        *j*) pool_explicit=-j ;;
    esac
    for pool_word in "$@"; do
        case "$pool_word" in
            --) break ;;
            --jobserver-auth=* | --jobserver-fds=*) pool_auth=${pool_word#*=} ;;
            -j*) pool_explicit=$pool_word ;;
        esac
    done
    set --
    if [[ -n $pool_auth ]]; then
        if jobserver_usable "$pool_auth"; then pool_args=(); fi
    elif [[ -n $pool_explicit ]]; then
        pool_args=("$pool_explicit")
    fi

    for shard in "${all_shards[@]}"; do
        cat > "$worker_root/invoke-worker-$shard.sh" <<SH
#!/usr/bin/env bash
set -u
run_worker_core '$shard' 0
SH
        # The wrapper makes the Busted shard its own process group, records
        # it for interrupt cleanup, and reports a shard that died before
        # recording its status.
        cat > "$worker_root/run-worker-$shard.sh" <<SH
#!/usr/bin/env bash
set -u
set -m
worker_root='$worker_root'
shard='$shard'

terminate_group() {
    local pid=\$1
    local attempt=
    if [[ -n \$pid ]] && kill -0 -- "-\$pid" 2>/dev/null; then
        kill -TERM -- "-\$pid" 2>/dev/null || true
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -z \$pid ]] || ! kill -0 -- "-\$pid" 2>/dev/null; then return; fi
        sleep 0.1
    done
    if [[ -n \$pid ]] && kill -0 -- "-\$pid" 2>/dev/null; then
        kill -KILL -- "-\$pid" 2>/dev/null || true
    fi
}

bash "\$worker_root/invoke-worker-\$shard.sh" &
worker_pid=\$!
printf '%s\n' "\$worker_pid" > "\$worker_root/worker-\$shard.pid"
trap 'terminate_group "\$worker_pid"; rm -f "\$worker_root/worker-\$shard.pid"; exit 143' HUP INT TERM

wait_status=0
wait "\$worker_pid" || wait_status=\$?
trap - HUP INT TERM
terminate_group "\$worker_pid"
wait "\$worker_pid" 2>/dev/null || true
rm -f "\$worker_root/worker-\$shard.pid"

status_file="\$worker_root/shard-\$shard.status"
recorded_status=
if [[ -f \$status_file ]]; then
    read -r recorded_status < "\$status_file" || recorded_status=
fi
if [[ ! \$recorded_status =~ ^[0-9]+$ ]]; then
    echo "compiler shard \$shard exited before recording its status: status=\$wait_status" >&2
    if (( wait_status == 0 )); then wait_status=1; fi
    printf '%s\n' "\$wait_status" > "\$status_file"
    exit "\$wait_status"
elif (( wait_status != recorded_status )); then
    echo "compiler shard \$shard status disagreement: reported=\$recorded_status wait=\$wait_status" >&2
    printf '1\n' > "\$status_file"
    exit 1
fi
exit "\$recorded_status"
SH
        chmod +x "$worker_root/invoke-worker-$shard.sh" \
            "$worker_root/run-worker-$shard.sh" || exit 1
    done
    export workspace worker_root busted windows
    export -f tag_output run_worker_core

    if (( build_native != 0 )); then
        cat > "$worker_root/run-native-build.sh" <<SH
#!/usr/bin/env bash
set -u
make_cmd=\$1
started=\$SECONDS
echo "===== starting native stdlib test build ====="
status=0
"\$make_cmd" --no-print-directory -C '$workspace' titan-stdlib-test-build 2>&1 |
    while IFS= read -r line || [[ -n \$line ]]; do
        printf '[native build] %s\n' "\$line"
    done
status=\${PIPESTATUS[0]}
printf '%s\n' "\$status" > '$worker_root/native-build.status' || exit 1
echo "===== finished native stdlib test build: status=\$status, \$((SECONDS - started))s ====="
# The launcher reports the recorded status; the graph status covers shards.
exit 0
SH
        chmod +x "$worker_root/run-native-build.sh" || exit 1
    fi

    # Safe ASCII phony IDs; the native build is ordered first so it starts
    # before the Busted shards claim the remaining slots.
    graph_targets=()
    if (( build_native != 0 )); then graph_targets+=(native-build); fi
    for shard in "${ordinary_shards[@]}"; do
        graph_targets+=("shard-$shard")
    done
    {
        printf '.PHONY: all %s\n' "${graph_targets[*]}"
        printf 'all: %s\n\n' "${graph_targets[*]}"
        if (( build_native != 0 )); then
            printf 'native-build:\n'
            printf '\t+@bash '\''%s/run-native-build.sh'\'' '\''$(MAKE)'\''\n\n' \
                "$worker_root"
        fi
        for shard in "${ordinary_shards[@]}"; do
            printf 'shard-%s:\n' "$shard"
            printf '\t@bash '\''%s/run-worker-%s.sh'\''\n\n' "$worker_root" "$shard"
        done
    } > "$worker_root/work-graph.mk"

    make_cmd=${MAKE:-make}
    defer_launch_signals
    "$make_cmd" --no-print-directory -k ${pool_args[@]+"${pool_args[@]}"} \
        -f "$worker_root/work-graph.mk" all &
    graph_pid=$!
    finish_launch
    graph_status=0
    wait "$graph_pid" || graph_status=$?
    graph_pid=
    if (( graph_status != 0 )); then scheduler_status=1; fi

    # The genuinely exclusive files run alone, after every ordinary shard and
    # the native build have finished.
    if [[ -n $exclusive_shard ]]; then
        defer_launch_signals
        bash "$worker_root/run-worker-$exclusive_shard.sh" &
        worker_pids[$exclusive_shard]=$!
        finish_launch
        exclusive_status=0
        wait "${worker_pids[$exclusive_shard]}" || exclusive_status=$?
        unset 'worker_pids[$exclusive_shard]'
        if (( exclusive_status != 0 )); then scheduler_status=1; fi
    fi
else
    run_worker() {
        run_worker_core "$1" 1
    }

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
        defer_launch_signals
        run_worker "$shard" &
        worker_pids[$shard]=$!
        monitor_worker "$shard" "${worker_pids[$shard]}" &
        monitor_pids[$shard]=$!
        finish_launch
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

    # The exclusive shard runs first and alone, so its explicit native job
    # bound does not multiply with another active shard; the ordinary shards
    # then share the worker slots.
    windows_launch_order() {
        launch_order=()
        if [[ -n $exclusive_shard ]]; then launch_order+=("$exclusive_shard"); fi
        launch_order+=("${ordinary_shards[@]}")
    }

    windows_may_launch() {
        local shard=$1
        (( active < jobs )) || return 1
        if [[ -n $exclusive_shard ]]; then
            if [[ $shard == "$exclusive_shard" ]]; then
                (( active == 0 )) || return 1
            elif [[ -n ${worker_pids[$exclusive_shard]-} ]]; then
                return 1
            fi
        fi
        return 0
    }

    if ! mkfifo "$completion_fifo"; then
        echo "could not create compiler worker completion channel" >&2
        exit 1
    fi
    exec 9<> "$completion_fifo"

    launched=0
    active=0
    completed=0
    total_shards=${#all_shards[@]}
    windows_launch_order
    while (( completed < total_shards )); do
        while (( launched < total_shards )) &&
              windows_may_launch "${launch_order[$launched]}"; do
            launch_worker "${launch_order[$launched]}"
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
        if [[ ! $completed_shard =~ ^[1-9][0-9]*$ ||
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

        if [[ -z ${worker_pids[$completed_shard]-} ]]; then continue; fi

        pid=${worker_pids[$completed_shard]}
        if [[ $completed_source == monitor ]]; then
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
fi

status=$scheduler_status
if (( build_native != 0 )); then
    native_build_status=
    if [[ -f $worker_root/native-build.status ]]; then
        read -r native_build_status < "$worker_root/native-build.status" ||
            native_build_status=
    fi
    if [[ ! $native_build_status =~ ^[0-9]+$ ]]; then native_build_status=1; fi
    if [[ -n $native_status_file ]]; then
        # The caller owns the native phase and reports this status there.
        printf '%s\n' "$native_build_status" > "$native_status_file" || status=1
    elif (( native_build_status != 0 )); then
        echo "native stdlib test build failed: status=$native_build_status" >&2
        status=1
    fi
fi

for shard in "${all_shards[@]}"; do
    if [[ ! -s $worker_root/shard-$shard.log ]]; then
        echo "compiler shard $shard produced no readable tagged log" >&2
        status=1
    fi
    shard_status=
    if [[ -f $worker_root/shard-$shard.status ]]; then
        read -r shard_status < "$worker_root/shard-$shard.status" ||
            shard_status=
    fi
    if [[ ! $shard_status =~ ^[0-9]+$ || $shard_status != 0 ]]; then
        echo "compiler shard $shard failed: ${shard_status:-missing status}" >&2
        status=1
    fi
done

# Every planned file must report exactly one PASS or FAIL row.
passed_files=0
failed_files=0
failed_file_records=()
: > "$worker_root/recorded-files"
for shard in "${all_shards[@]}"; do
    [[ -f $worker_root/shard-$shard.files ]] || continue
    while IFS=$'\t' read -r result record_shard test_file file_status file_elapsed; do
        [[ -n ${result:-} ]] || continue
        printf '%s\n' "$test_file" >> "$worker_root/recorded-files"
        if [[ $result == PASS ]]; then
            passed_files=$((passed_files + 1))
        else
            failed_files=$((failed_files + 1))
            failed_file_records+=("FAILED spec file: $test_file (shard $record_shard, status=$file_status, ${file_elapsed}s)")
        fi
    done < "$worker_root/shard-$shard.files"
done
for shard in "${all_shards[@]}"; do
    cat "$worker_root/files-$shard.txt"
done | LC_ALL=C sort > "$worker_root/planned-files.sorted"
LC_ALL=C sort "$worker_root/recorded-files" > "$worker_root/recorded-files.sorted"
while IFS= read -r test_file; do
    echo "spec file reported more than once: $test_file" >&2
    status=1
done < <(LC_ALL=C uniq -d "$worker_root/recorded-files.sorted")
while IFS= read -r test_file; do
    echo "planned spec file did not report a result: $test_file" >&2
    status=1
done < <(LC_ALL=C comm -23 "$worker_root/planned-files.sorted" \
    "$worker_root/recorded-files.sorted")
while IFS= read -r test_file; do
    echo "unplanned spec file reported a result: $test_file" >&2
    status=1
done < <(LC_ALL=C comm -13 "$worker_root/planned-files.sorted" \
    "$worker_root/recorded-files.sorted")
if (( failed_files != 0 )); then status=1; fi

echo "Per-file Busted summary: passed=$passed_files failed=$failed_files total=$((passed_files + failed_files))"
for record in "${failed_file_records[@]+"${failed_file_records[@]}"}"; do
    echo "$record" >&2
done

if (( status != 0 )); then exit 1; fi
echo "All ${#all_shards[@]} compiler shards passed"

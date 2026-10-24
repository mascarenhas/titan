#!/usr/bin/env bash

# Parallel native stdlib aggregate runner for Unix.
# Derives owner groups from TITAN_STDLIB_TEST_ROOTS via stdlib_test_modules.mk,
# partitions ordinary owners by LPT into up to TITAN_TEST_JOBS workers, then
# runs timing-guarded owners alone after the ordinary pool drains.
# Compatible with macOS Bash 3.2 (no wait -n, associative arrays, or mapfile).

set -u

jobs=${TITAN_TEST_JOBS:-4}
if [[ ! $jobs =~ ^[1-9][0-9]*$ || ${#jobs} -gt 9 ]]; then
    echo "TITAN_TEST_JOBS must be a positive integer" >&2
    exit 2
fi

executable=${TITAN_TEST_EXECUTABLE:-out/tests/test/tests}
if [[ ! -x $executable ]]; then
    echo "ERROR: run 'make titan-stdlib-test-build' first" >&2
    exit 1
fi

timeout_seconds=${TITAN_TEST_TIMEOUT:-600}
if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
    echo "TITAN_TEST_TIMEOUT must be a positive integer" >&2
    exit 2
fi

run_log=${TITAN_TEST_RUN_LOG:-out/tests/stdout.log}
run_roots=${TITAN_TEST_RUN_ROOTS:-${run_log}.roots}
test_lua=${TEST_LUA:-lua}
make_cmd=${MAKE:-make}
manifest=${TITAN_TEST_MODULE_MANIFEST:-spec/support/stdlib_test_modules.mk}

workspace=$(pwd -P) || exit 1
temporary_base=${TMPDIR:-/tmp}
if ! temporary_base=$(cd "$temporary_base" 2>/dev/null && pwd -P); then
    echo "parallel native tests require an existing temporary directory" >&2
    exit 2
fi

parallel_root=$(mktemp -d "$temporary_base/titan-stdlib-test-workers.XXXXXX") || exit 1
completion_fifo=$parallel_root/completions
group_pids=()
monitor_pids=()
cleanup_started=0
pending_signal=0

terminate_groups() {
    local idx=
    local pid=
    local attempt=
    local running=

    for idx in "${!group_pids[@]}" "${!monitor_pids[@]}"; do
        for pid in "${group_pids[$idx]-}" "${monitor_pids[$idx]-}"; do
            if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                kill -TERM -- "-$pid" 2>/dev/null || true
            fi
        done
    done

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        running=0
        for idx in "${!group_pids[@]}" "${!monitor_pids[@]}"; do
            for pid in "${group_pids[$idx]-}" "${monitor_pids[$idx]-}"; do
                if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                    running=1
                    break 2
                fi
            done
        done
        if (( running == 0 )); then break; fi
        sleep 0.1
    done

    for idx in "${!group_pids[@]}" "${!monitor_pids[@]}"; do
        for pid in "${group_pids[$idx]-}" "${monitor_pids[$idx]-}"; do
            if [[ -n $pid ]] && kill -0 -- "-$pid" 2>/dev/null; then
                kill -KILL -- "-$pid" 2>/dev/null || true
            fi
        done
    done
    for idx in "${!group_pids[@]}" "${!monitor_pids[@]}"; do
        for pid in "${group_pids[$idx]-}" "${monitor_pids[$idx]-}"; do
            if [[ -n $pid ]]; then wait "$pid" 2>/dev/null || true; fi
        done
        unset 'group_pids[$idx]'
        unset 'monitor_pids[$idx]'
    done
}

cleanup() {
    if (( cleanup_started != 0 )); then return; fi
    cleanup_started=1
    trap - EXIT
    trap '' HUP INT TERM
    terminate_groups
    { exec 9>&-; } 2>/dev/null || true
    case "$parallel_root" in
        "$temporary_base"/titan-stdlib-test-workers.*)
            rm -rf -- "$parallel_root"
            ;;
        *)
            echo "refusing to remove unexpected worker path: $parallel_root" >&2
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

mkdir -p "$(dirname "$run_log")" "$(dirname "$run_roots")" || exit 1

schedule_file=$parallel_root/owner-schedule.txt
make_args=(--no-print-directory -s -f "$manifest" print-stdlib-test-owner-schedule)
if [[ -n ${TITAN_STDLIB_TEST_ROOTS:-} ]]; then
    make_args+=("TITAN_STDLIB_TEST_ROOTS=$TITAN_STDLIB_TEST_ROOTS")
fi
if ! "$make_cmd" "${make_args[@]}" > "$schedule_file"; then
    echo "could not query native stdlib test owner schedule from $manifest" >&2
    exit 2
fi

"$test_lua" -E - "$schedule_file" "$jobs" "$parallel_root" "$run_roots" <<'LUA' || exit $?
local schedule_path, jobs_arg, out_dir, roots_out = ...
local n = tonumber(jobs_arg)
if not n or n < 1 or math.floor(n) ~= n then
    io.stderr:write("TITAN_TEST_JOBS must be a positive integer\n")
    os.exit(2)
end

local f = assert(io.open(schedule_path, "rb"))
local text = assert(f:read("*a"))
assert(f:close())

local roots = {}
local seen = {}
local ordinary = {}
local guarded = {}

for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw_line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if line ~= "" then
        local owner, sec_str, mode = line:match("^([^:]+):([^:]+):([^:]+)$")
        local sec = tonumber(sec_str)
        if not owner or owner == "" or not sec or sec < 0 or
           (mode ~= "ordinary" and mode ~= "guarded") then
            io.stderr:write("invalid native owner schedule entry: " .. line .. "\n")
            os.exit(2)
        end
        if seen[owner] then
            io.stderr:write("duplicate native test root: " .. owner .. "\n")
            os.exit(2)
        end
        seen[owner] = true
        roots[#roots + 1] = owner
        local entry = { owner = owner, seconds = sec, order = #roots }
        if mode == "guarded" then
            guarded[#guarded + 1] = entry
        else
            ordinary[#ordinary + 1] = entry
        end
    end
end

if #roots == 0 then
    io.stderr:write("empty native test root inventory\n")
    os.exit(2)
end

local function write_lines(path, lines)
    local out = assert(io.open(path, "wb"))
    for _, line in ipairs(lines) do
        assert(out:write(line, "\n"))
    end
    assert(out:close())
end

write_lines(roots_out, roots)

local function owner_filter_pattern(owner)
    return "^" .. owner:gsub("%.", "[.]") .. "[.]test_"
end

table.sort(ordinary, function(a, b)
    if a.seconds ~= b.seconds then return a.seconds > b.seconds end
    return a.owner < b.owner
end)

local effective_ordinary = math.min(n, #ordinary)
local workers = {}
for i = 1, effective_ordinary do
    workers[i] = { index = i, load = 0, owners = {} }
end
for _, item in ipairs(ordinary) do
    local best = workers[1]
    for i = 2, effective_ordinary do
        if workers[i].load < best.load then
            best = workers[i]
        end
    end
    best.owners[#best.owners + 1] = item.owner
    best.load = best.load + item.seconds
end

local group_ids = {}
for i, w in ipairs(workers) do
    table.sort(w.owners)
    local gid = tostring(i)
    group_ids[#group_ids + 1] = gid
    write_lines(out_dir .. "/owners-" .. gid .. ".txt", w.owners)
    local filters = {}
    for _, owner in ipairs(w.owners) do
        filters[#filters + 1] = "--filter=" .. owner_filter_pattern(owner)
    end
    write_lines(out_dir .. "/filters-" .. gid .. ".txt", filters)
end

local has_guarded = 0
if #guarded > 0 then
    has_guarded = 1
    local guarded_owners = {}
    for _, item in ipairs(guarded) do
        guarded_owners[#guarded_owners + 1] = item.owner
    end
    table.sort(guarded_owners)
    write_lines(out_dir .. "/owners-guarded.txt", guarded_owners)
    local filters = {}
    for _, owner in ipairs(guarded_owners) do
        filters[#filters + 1] = "--filter=" .. owner_filter_pattern(owner)
    end
    write_lines(out_dir .. "/filters-guarded.txt", filters)
end

write_lines(out_dir .. "/plan.summary", {
    "ordinary_groups=" .. tostring(#workers),
    "has_guarded=" .. tostring(has_guarded),
})
LUA

ordinary_groups=0
has_guarded=0
while IFS='=' read -r key val; do
    case "$key" in
        ordinary_groups) ordinary_groups=$val ;;
        has_guarded) has_guarded=$val ;;
    esac
done < "$parallel_root/plan.summary"

if ! mkfifo "$completion_fifo"; then
    echo "could not create native test worker completion channel" >&2
    exit 1
fi
exec 9<> "$completion_fifo"

tag_group_output() {
    local label=$1
    local line=
    while IFS= read -r line || [[ -n $line ]]; do
        printf '[stdlib group %s] %s\n' "$label" "$line"
    done
}

run_group() {
    local idx=$1
    local label=$2
    local group_dir=$parallel_root/group-$label
    local group_tmp=$group_dir/tmp
    local raw_log=$group_dir/stdout.log
    local status_file=$group_dir/status
    local filters_file=$parallel_root/filters-$label.txt
    local filter_args=()
    local filter_line=
    local started=$SECONDS
    local status=0
    local -a pipeline_status

    mkdir -p "$group_tmp" || exit 1
    while IFS= read -r filter_line || [[ -n $filter_line ]]; do
        [[ -n $filter_line ]] || continue
        filter_args+=("$filter_line")
    done < "$filters_file"

    printf '===== starting native stdlib group %s =====\n' "$label"
    # The subshell reports the supervised executable's status (124 after a
    # timeout), not tee's: a passing report followed by a failing exit must
    # fail the group. A raw log that could not be written also fails it.
    (
        export TMPDIR="$group_tmp"
        export TITAN_TEST_ROOT="$group_tmp"
        bash spec/support/run_with_timeout.sh "$timeout_seconds" \
            "$executable" "${filter_args[@]}" 2>&1 | tee "$raw_log"
        run_status=("${PIPESTATUS[@]}")
        if (( run_status[0] != 0 )); then exit "${run_status[0]}"; fi
        exit "${run_status[1]}"
    ) 2>&1 | tag_group_output "$label"
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if (( pipeline_status[1] != 0 )); then
        if (( status == 0 )); then status=1; fi
    fi
    printf '%s\n' "$status" > "$status_file"
    printf '===== finished native stdlib group %s: status=%s, %ss =====\n' \
        "$label" "$status" "$((SECONDS - started))"
    printf '%s worker %s\n' "$idx" "$status" >&9 || exit 1
    return "$status"
}

monitor_group() {
    local idx=$1
    local worker_pid=$2
    while kill -0 "$worker_pid" 2>/dev/null; do sleep 0.1; done
    printf '%s monitor\n' "$idx" >&9
}

terminate_one_group() {
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

launch_group() {
    local idx=$1
    local label=$2
    local worker_pid=
    local monitor_pid=
    local deferred_status=

    defer_launch_signals
    run_group "$idx" "$label" &
    worker_pid=$!
    group_pids[$idx]=$worker_pid
    monitor_group "$idx" "$worker_pid" &
    monitor_pid=$!
    monitor_pids[$idx]=$monitor_pid
    install_signal_handlers

    if (( pending_signal != 0 )); then
        deferred_status=$pending_signal
        pending_signal=0
        handle_signal "$deferred_status"
    fi
}

stop_group_monitor() {
    local idx=$1
    local monitor_pid=${monitor_pids[$idx]-}
    if [[ -z $monitor_pid ]]; then return; fi
    if kill -0 -- "-$monitor_pid" 2>/dev/null; then
        kill -TERM -- "-$monitor_pid" 2>/dev/null || true
    fi
    wait "$monitor_pid" 2>/dev/null || true
    unset 'monitor_pids[$idx]'
}

set -m

scheduler_status=0
launched=0
active=0
completed=0

while (( completed < ordinary_groups )); do
    while (( launched < ordinary_groups && active < jobs )); do
        launched=$((launched + 1))
        launch_group "$launched" "$launched"
        active=$((active + 1))
    done

    completed_idx=
    completed_source=
    completed_status=
    completed_extra=
    if ! IFS=' ' read -r completed_idx completed_source \
        completed_status completed_extra <&9; then
        echo "could not read native test worker completion" >&2
        scheduler_status=1
        break
    fi
    if [[ ! $completed_idx =~ ^[0-9]+$ ||
          ! $completed_source =~ ^(worker|monitor)$ ||
          -n $completed_extra ]]; then
        echo "invalid native test worker completion: $completed_idx $completed_source $completed_status $completed_extra" >&2
        scheduler_status=1
        break
    fi
    if [[ -z ${group_pids[$completed_idx]-} ]]; then continue; fi

    pid=${group_pids[$completed_idx]}
    if [[ $completed_source == monitor ]]; then
        terminate_one_group "$pid"
    fi
    wait_status=0
    wait "$pid" || wait_status=$?
    unset 'group_pids[$completed_idx]'
    stop_group_monitor "$completed_idx"
    active=$((active - 1))
    completed=$((completed + 1))
    if [[ $completed_source == monitor ]]; then
        echo "native stdlib group $completed_idx exited before completion notification: status=$wait_status" >&2
        printf '%s\n' "$wait_status" > "$parallel_root/group-$completed_idx/status" || scheduler_status=1
    elif (( wait_status != completed_status )); then
        echo "native stdlib group $completed_idx status disagreement: reported=$completed_status wait=$wait_status" >&2
        scheduler_status=1
    fi
done

# Guarded timing-sensitive owners run alone after all ordinary workers finish.
if (( has_guarded != 0 )); then
    guarded_idx=$((ordinary_groups + 1))
    launch_group "$guarded_idx" "guarded"
    while [[ -n ${group_pids[$guarded_idx]-} ]]; do
        completed_idx=
        completed_source=
        completed_status=
        completed_extra=
        if ! IFS=' ' read -r completed_idx completed_source \
            completed_status completed_extra <&9; then
            echo "could not read guarded native test worker completion" >&2
            scheduler_status=1
            break
        fi
        if [[ $completed_idx != "$guarded_idx" ]]; then continue; fi
        pid=${group_pids[$guarded_idx]}
        if [[ $completed_source == monitor ]]; then
            terminate_one_group "$pid"
        fi
        wait_status=0
        wait "$pid" || wait_status=$?
        unset 'group_pids[$guarded_idx]'
        stop_group_monitor "$guarded_idx"
        if [[ $completed_source == monitor ]]; then
            echo "native stdlib group guarded exited before completion notification: status=$wait_status" >&2
            printf '%s\n' "$wait_status" > "$parallel_root/group-guarded/status" || scheduler_status=1
        elif (( wait_status != completed_status )); then
            echo "native stdlib group guarded status disagreement: reported=$completed_status wait=$wait_status" >&2
            scheduler_status=1
        fi
    done
fi

: > "$run_log"
all_labels=()
for ((idx = 1; idx <= ordinary_groups; idx++)); do
    all_labels+=("$idx")
done
if (( has_guarded != 0 )); then
    all_labels+=("guarded")
fi

union_args=(--union "$run_roots")
status=$scheduler_status
for label in "${all_labels[@]}"; do
    glog=$parallel_root/group-$label/stdout.log
    gstatus_file=$parallel_root/group-$label/status
    gowners=$parallel_root/owners-$label.txt
    if [[ -f $glog ]]; then
        cat "$glog" >> "$run_log"
    fi
    gstatus=
    if [[ -f $gstatus_file ]]; then
        read -r gstatus < "$gstatus_file" || gstatus=
    fi
    if [[ ! $gstatus =~ ^[0-9]+$ || $gstatus != 0 ]]; then
        echo "native stdlib group $label failed: ${gstatus:-missing status}" >&2
        status=1
    fi
    union_args+=("$label" "$glog" "$gowners")
done

audit_status=0
"$test_lua" -E spec/support/check_stdlib_test_output.lua "${union_args[@]}" || audit_status=$?
if (( status != 0 )); then exit "$status"; fi
exit "$audit_status"

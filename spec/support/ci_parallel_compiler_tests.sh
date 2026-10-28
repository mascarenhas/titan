#!/usr/bin/env bash

set -u

shards=(1 2 3 4)
group=compiler-shard-
label=compiler
# Ordinary workers share the runner's CPUs: two per 2-CPU compiler runner.
worker_jobs=1
case "${1-all}" in
    all) ;;
    1-2) shards=(1 2) ;;
    3-4) shards=(3 4) ;;
    stdlib)
        # The stdlib job's two installed-stdlib workers share four CPUs.
        shards=(1 2)
        group=stdlib-compiler-shard-
        label="stdlib compiler"
        worker_jobs=2
        ;;
    *)
        echo "usage: $0 [all|1-2|3-4|stdlib]" >&2
        exit 2
        ;;
esac
if (( $# > 1 )); then
    echo "usage: $0 [all|1-2|3-4|stdlib]" >&2
    exit 2
fi

workspace=${GITHUB_WORKSPACE:-$PWD}
runner_temp=${RUNNER_TEMP:-/tmp}
archive=${TITAN_PREPARED_ARCHIVE:-$runner_temp/titan-linux-prepared.tar.gz}
busted=${BUSTED:-$workspace/.lua/bin/busted}
lua=${LUA:-$workspace/.lua/bin/lua}

if [[ $workspace != /* || $runner_temp != /* || ! -d $runner_temp ||
      ! -f $archive || ! -x $busted || ! -x $lua ]]; then
    echo "parallel compiler tests require absolute workspace/runner paths, " \
        "the prepared archive, and the prepared Lua tools" >&2
    exit 2
fi
worker_root=$(mktemp -d "$runner_temp/titan-compiler-workers.XXXXXX") ||
    exit 1

cleanup() {
    rm -rf -- "$worker_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export archive worker_root
if ! printf '%s\n' "${shards[@]}" | xargs -r -n1 -P2 bash -c '
    shard=$1
    worker=$worker_root/work-$shard
    mkdir -p "$worker" || exit 1
    tar --exclude="./.lua" --exclude="./.git" \
        -xzf "$archive" -C "$worker" || exit 1
' _; then
    echo "could not prepare isolated compiler test workers" >&2
    exit 1
fi

export workspace worker_root busted group label worker_jobs
# Run one phase of one covered+stress shard in its private extraction. Its
# LuaCov stats accumulate across both phases in that extraction.
run_shard_phase='
    phase=$1
    shard=$2
    worker=$worker_root/work-$shard
    log=$worker_root/shard-$shard.log
    started=$SECONDS
    printf "===== starting %s covered+stress shard %s (%s files) =====\n" "$label" "$shard" "$phase"
    (
        cd "$worker" || exit 1
        if [[ $phase == ordinary ]]; then
            rm -f luacov.stats.out luacov.report.out || exit 1
        fi
        mkdir -p .tmp || exit 1
        export TMPDIR="$PWD/.tmp"
        unset LUACOV_CONFIG
        if [[ $phase == exclusive ]]; then
            # These files run alone and set their own compiler and Make
            # caps; titanc reads an inherited -j1 as a serial job policy.
            env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS \
                BUSTED="$busted" \
                bash spec/support/ci_test_groups.sh "$group$shard" "$phase"
        else
            BUSTED="$busted" MAKEFLAGS=-j$worker_jobs TITAN_JOBS=$worker_jobs \
                bash spec/support/ci_test_groups.sh "$group$shard" "$phase"
        fi
    ) 2>&1 | sed -u "s/^/[$label shard $shard] /" | tee -a "$log"
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if (( pipeline_status[1] != 0 || pipeline_status[2] != 0 )); then
        status=1
    fi
    printf "===== finished %s covered+stress shard %s (%s files): status=%s, %ss =====\n" "$label" \
        "$shard" "$phase" "$status" "$((SECONDS - started))"
    printf "%s\n" "$status" > "$worker_root/shard-$shard.$phase.status"
    exit "$status"
'
# The two shards share this runner concurrently. Files that count real
# overlapping compiler processes or drive real Make jobservers then run
# alone, one shard after the other.
xargs_status=0
printf '%s\n' "${shards[@]}" | xargs -r -n1 -P2 bash -c "$run_shard_phase" _ \
    ordinary || xargs_status=$?
printf '%s\n' "${shards[@]}" | xargs -r -n1 -P1 bash -c "$run_shard_phase" _ \
    exclusive || xargs_status=$?

status=$xargs_status
for shard in "${shards[@]}"; do
    if [[ ! -s $worker_root/shard-$shard.log ]]; then
        echo "$label shard $shard produced no readable log" >&2
        status=1
    fi
    for phase in ordinary exclusive; do
        shard_status=
        if [[ -f $worker_root/shard-$shard.$phase.status ]]; then
            read -r shard_status < "$worker_root/shard-$shard.$phase.status"
        fi
        if [[ ! $shard_status =~ ^[0-9]+$ || $shard_status != 0 ]]; then
            echo "$label shard $shard ($phase files) failed: " \
                "${shard_status:-missing status}" >&2
            status=1
        fi
    done
done
if (( status != 0 )); then exit 1; fi

stats=()
for shard in "${shards[@]}"; do
    file=$worker_root/work-$shard/luacov.stats.out
    if [[ ! -f $file ]]; then
        echo "$label shard $shard produced no LuaCov stats" >&2
        exit 1
    fi
    stats+=("$file")
done
rm -f "$workspace/luacov.stats.out"
"$lua" "$workspace/spec/support/merge_luacov_stats.lua" \
    "$workspace/luacov.stats.out" "${stats[@]}"

#!/usr/bin/env bash

set -u

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
if ! printf '%s\n' 1 2 3 4 | xargs -r -n1 -P2 bash -c '
    shard=$1
    worker=$worker_root/work-$shard
    mkdir -p "$worker" || exit 1
    tar --exclude="./.lua" --exclude="./.git" \
        -xzf "$archive" -C "$worker" || exit 1
' _; then
    echo "could not prepare isolated compiler test workers" >&2
    exit 1
fi

export workspace worker_root busted
xargs_status=0
printf '%s\n' 1 2 3 4 | xargs -r -n1 -P2 bash -c '
    shard=$1
    worker=$worker_root/work-$shard
    log=$worker_root/shard-$shard.log
    started=$SECONDS
    printf "===== starting compiler coverage shard %s =====\n" "$shard"
    (
        cd "$worker" || exit 1
        rm -f luacov.stats.out luacov.report.out || exit 1
        mkdir -p .tmp || exit 1
        export TMPDIR="$PWD/.tmp"
        unset LUACOV_CONFIG
        BUSTED="$busted" MAKEFLAGS=-j1 TITAN_JOBS=1 \
            bash spec/support/ci_test_groups.sh "compiler-shard-$shard"
    ) 2>&1 | sed -u "s/^/[compiler shard $shard] /" | tee "$log"
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if (( pipeline_status[1] != 0 || pipeline_status[2] != 0 )); then
        status=1
    fi
    printf "===== finished compiler coverage shard %s: status=%s, %ss =====\n" \
        "$shard" "$status" "$((SECONDS - started))"
    printf "%s\n" "$status" > "$worker_root/shard-$shard.status"
    exit "$status"
' _ || xargs_status=$?

status=$xargs_status
for shard in 1 2 3 4; do
    if [[ ! -s $worker_root/shard-$shard.log ]]; then
        echo "compiler coverage shard $shard produced no readable log" >&2
        status=1
    fi
    shard_status=
    if [[ -f $worker_root/shard-$shard.status ]]; then
        read -r shard_status < "$worker_root/shard-$shard.status"
    fi
    if [[ ! $shard_status =~ ^[0-9]+$ || $shard_status != 0 ]]; then
        echo "compiler coverage shard $shard failed: " \
            "${shard_status:-missing status}" >&2
        status=1
    fi
done
if (( status != 0 )); then exit 1; fi

stats=()
for shard in 1 2 3 4; do
    file=$worker_root/work-$shard/luacov.stats.out
    if [[ ! -f $file ]]; then
        echo "compiler coverage shard $shard produced no LuaCov stats" >&2
        exit 1
    fi
    stats+=("$file")
done
rm -f "$workspace/luacov.stats.out"
"$lua" "$workspace/spec/support/merge_luacov_stats.lua" \
    "$workspace/luacov.stats.out" "${stats[@]}"

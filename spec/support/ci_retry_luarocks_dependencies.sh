#!/usr/bin/env bash

# Retry only LuaRocks dependency-acquisition commands. A failed CI job does not
# publish its prefix cache, while a retry inside the same job preserves every
# dependency that LuaRocks installed before a transient download failure.

set -eu

if [[ $# -eq 0 ]]; then
    echo "usage: ci_retry_luarocks_dependencies.sh COMMAND [ARG ...]" >&2
    exit 64
fi

base_delay=${TITAN_CI_LUAROCKS_RETRY_DELAY_SECONDS:-5}
if [[ ! $base_delay =~ ^[0-9]+$ ]]; then
    echo "TITAN_CI_LUAROCKS_RETRY_DELAY_SECONDS must be a nonnegative integer" >&2
    exit 64
fi

for attempt in 1 2 3; do
    if "$@"; then
        exit 0
    else
        status=$?
    fi

    if [[ $attempt -eq 3 ]]; then
        exit "$status"
    fi

    delay=$((attempt * base_delay))
    printf 'LuaRocks dependency acquisition failed (attempt %s/3, exit %s); retrying in %ss\n' \
        "$attempt" "$status" "$delay" >&2
    if [[ $delay -gt 0 ]]; then
        sleep "$delay"
    fi
done

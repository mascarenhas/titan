#!/bin/sh
# Run the shared browser SDK stages. The Make recipe owns environment setup
# and the dry-run/query/touch guard.
set -eu

lua=$1
build_dir=$2
repository=$3
release=$4
exe_suffix=$5
path_key=$6
compiler_remedy=$7
shift 7

if [ -z "${TITAN_NODE:-}" ]; then unset TITAN_NODE; fi

titanc="$TITAN_INSTALL_TREE/bin/titanc$exe_suffix"
if [ ! -x "$titanc" ]; then titanc="$PREFIX/bin/titanc$exe_suffix"; fi
if [ ! -x "$titanc" ]; then
    printf 'browser-sdk: installed titanc not found; %s\n' "$compiler_remedy" >&2
    exit 1
fi

"$lua" -E scripts/browser_sdk.lua prepare "$build_dir" "$repository"
if [ "$exe_suffix" = .exe ]; then
    TITAN_ROOT="$PREFIX" TITAN_PATH= TITAN_EXTRA_CPPFLAGS= TITAN_EXTRA_CFLAGS= TITAN_EXTRA_LDFLAGS= \
        env -u LUA_PATH -u LUA_CPATH "$path_key=$PREFIX/lib/titan/$release" \
        "$titanc" --target windows --no-uv-bootstrap --incremental "-j$TITAN_JOBS" \
        --tree "$repository/titan-runtime/browser" --output "$build_dir.windows-host" \
        --exe "$build_dir.windows-host/bin/titan-browser-job.exe" _titan_browser.windows_job
fi

verbosity=-q
if [ "$TITAN_VERBOSE" = 1 ]; then verbosity=-v; fi

# Collect the object paths without interpreting either spaces or glob syntax.
c_objects=$("$titanc" --target browser --output "$build_dir" -c --incremental \
    "-j$TITAN_JOBS" "$verbosity" --print-c-objects "$@")
if [ "$exe_suffix" = .exe ]; then c_objects=$(printf '%s' "$c_objects" | tr -d '\r'); fi
nl=$(printf '\nX'); nl=${nl%X}
set -f; IFS=$nl; set -- $c_objects; set +f; unset IFS
"$lua" -E scripts/browser_sdk.lua stage-runtime "$build_dir" "$repository" "$@"

"$titanc" --target browser --output "$build_dir" --source-first --incremental "-j$TITAN_JOBS" \
    -X "$TITAN_INSTALL_TREE/lib/titan-browser/$release/libtitan-lpeglabel.a" \
    "$verbosity" $BROWSER_STDLIB_ROOTS
"$lua" -E scripts/browser_sdk.lua finalize "$build_dir"

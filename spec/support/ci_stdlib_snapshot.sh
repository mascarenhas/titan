#!/usr/bin/env bash

# Some compiler specs rebuild the checkout runtime. Preserve that Make-owned
# archive plus the canonical installed standard-library image around those
# groups so later production smokes see the exact build that the library gates
# tested. The source-rock hook owns the installed provider and shims; this
# snapshot must not depend on a packaging spec having built checkout-root
# standard-library outputs as a side effect.

set -euo pipefail

mode=${1:-}
archive=${2:-}

if [[ -z $archive ]]; then
    echo "usage: $0 {save|restore} ARCHIVE" >&2
    exit 2
fi

workspace=$(pwd -P)
prefix=${PREFIX:-$workspace/.lua}
if [[ $prefix != /* ]]; then prefix=$workspace/$prefix; fi
prefix=$(CDPATH= cd "$prefix" && pwd -P)
case "$prefix" in
    "$workspace"/*) prefix_rel=${prefix#"$workspace"/} ;;
    *)
        echo "snapshot PREFIX must be inside the prepared workspace: $prefix" \
            >&2
        exit 2
        ;;
esac

provider=$prefix_rel/lib/titan/0.16/titan.so
shim_dir=$prefix_rel/share/lua/5.5/titan

artifacts=(
    titan-runtime/libtitan.a
    titan-runtime/.titan-runtime-archive-build-config
    "$provider"
    "$shim_dir/coroutine.lua" "$shim_dir/uv.lua"
    "$shim_dir/async.lua" "$shim_dir/timer.lua"
    "$shim_dir/fs.lua" "$shim_dir/net.lua" "$shim_dir/os.lua"
)

if [[ -d $provider.dSYM ]]; then artifacts+=("$provider.dSYM"); fi

remove_installed_artifacts() {
    rm -rf "$provider" "$provider.dSYM"
    rm -f "$shim_dir/coroutine.lua" "$shim_dir/uv.lua" \
        "$shim_dir/async.lua" "$shim_dir/timer.lua" \
        "$shim_dir/fs.lua" "$shim_dir/net.lua" "$shim_dir/os.lua"
}

case "$mode" in
    save)
        for artifact in "${artifacts[@]}"; do
            if [[ ! -e $artifact ]]; then
                echo "cannot snapshot missing prepared artifact: $artifact" >&2
                exit 1
            fi
        done
        tar -cpf "$archive" "${artifacts[@]}"
        ;;
    restore)
        remove_installed_artifacts
        tar -xpf "$archive"
        ;;
    *)
        echo "usage: $0 {save|restore} ARCHIVE" >&2
        exit 2
        ;;
esac

#!/usr/bin/env bash

# Some compiler specs rebuild the coroutine runtime. Preserve the prepared
# runtime archive and sole canonical standard-library image around those groups
# so later production smokes see the exact build that the library gates tested.

set -euo pipefail

mode=${1:-}
archive=${2:-}

if [[ -z $archive ]]; then
    echo "usage: $0 {save|restore} ARCHIVE" >&2
    exit 2
fi

artifacts=(
    titan-runtime/libtitan.a
    titan-runtime/.titan-runtime-archive-build-config
    titan/coroutine.so titan/uv.so titan/timer.so
    titan/fs.so titan/net.so titan/os.so
)

for module in coroutine uv timer fs net os; do
    if [[ -d titan/$module.so.dSYM ]]; then
        artifacts+=("titan/$module.so.dSYM")
    fi
done

case "$mode" in
    save)
        tar -cpf "$archive" "${artifacts[@]}"
        ;;
    restore)
        rm -rf titan/*.so.dSYM
        tar -xpf "$archive"
        ;;
    *)
        echo "usage: $0 {save|restore} ARCHIVE" >&2
        exit 2
        ;;
esac

#!/usr/bin/env bash

# Compiler specs intentionally rebuild and clean root artifacts. Preserve the
# prepared runtime and canonical standard-library image around those groups so
# later production smokes see the exact build that the library gates tested.

set -euo pipefail

mode=${1:-}
archive=${2:-}

if [[ -z $archive ]]; then
    echo "usage: $0 {save|restore} ARCHIVE" >&2
    exit 2
fi

artifacts=(
    titan-runtime/titan.o
    coroutine.so uv.so timer.so fs.so net.so os.so
    titan/coroutine.so titan/uv.so titan/timer.so
    titan/fs.so titan/net.so titan/os.so
)

case "$mode" in
    save)
        tar -cpf "$archive" "${artifacts[@]}"
        ;;
    restore)
        tar -xpf "$archive"
        ;;
    *)
        echo "usage: $0 {save|restore} ARCHIVE" >&2
        exit 2
        ;;
esac

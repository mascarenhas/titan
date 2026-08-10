#!/usr/bin/env bash

# Remove compiler-generated C/object files below spec/ without touching native
# C fixtures. Generated translation units sit beside a same-stem Titan source;
# this remains usable in source-rock trees that have no Git metadata.

set -euo pipefail

keep_output=false
if [[ ${1-} == --keep-output ]]; then
    keep_output=true
    shift
fi
if [[ $# -ne 0 ]]; then
    echo "usage: $0 [--keep-output]" >&2
    exit 2
fi

while IFS= read -r -d '' source; do
    if [[ -f ${source%.c}.titan ]]; then rm -f -- "$source"; fi
done < <(find spec -type f -name '*.c' -print0)

find spec -type f -name '*.o' -delete
if ! $keep_output; then rm -rf -- .titan-tests; fi

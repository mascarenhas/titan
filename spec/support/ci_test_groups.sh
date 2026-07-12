#!/usr/bin/env bash

# Keep compiler/language coverage separate from library behavior. LuaCov's
# debug hook makes repeated checks of large Titan library sources expensive,
# but those checks do not measure the Titan or C implementations themselves.

set -u

BUSTED=${BUSTED:-./lua_modules/bin/busted}
group=${1:-}
compiler_tests=()
compiler_unit_tests=()
tooling_tests=()
library_serial_tests=()
library_uv_fs_tests=()
library_net_os_tests=()

while IFS= read -r test_file; do
    case "$test_file" in
        spec/canary_spec.lua)
            # CI-selection tooling is neither compiler/language behavior nor a
            # library API. Run it in the uncovered serial group.
            tooling_tests+=("$test_file")
            ;;
        spec/driver_spec.lua | \
        spec/foreigntypes_spec.lua | \
        spec/types_spec.lua)
            # Run these tiny module-level tests in a fresh Busted process so
            # their direct unit coverage is independent of Busted's file
            # insulation and compiler modules loaded by earlier specs.
            compiler_unit_tests+=("$test_file")
            ;;
        spec/coder/coroutine_spec.lua | \
        spec/libuv_build_spec.lua | \
        spec/libuv_shim_spec.lua | \
        spec/minicoro_spec.lua | \
        spec/rockspec_spec.lua)
            # These suites mutate or inspect shared root artifacts, so keep
            # them out of the two private-workspace workers below.
            library_serial_tests+=("$test_file")
            ;;
        spec/checker/uv_spec.lua | \
        spec/checker/timer_spec.lua | \
        spec/checker/fs_spec.lua | \
        spec/coder/uv*_spec.lua | \
        spec/coder/timer*_spec.lua | \
        spec/coder/fs*_spec.lua)
            library_uv_fs_tests+=("$test_file")
            ;;
        spec/checker/net_spec.lua | \
        spec/checker/os_spec.lua | \
        spec/coder/net*_spec.lua | \
        spec/coder/os*_spec.lua)
            library_net_os_tests+=("$test_file")
            ;;
        *)
            compiler_tests+=("$test_file")
            ;;
    esac
done < <(find spec -type f -name '*_spec.lua' -print | LC_ALL=C sort)

uncovered_serial_tests=(
    "${tooling_tests[@]}"
    "${library_serial_tests[@]}"
)

case "$group" in
    compiler)
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]}))
        echo "Running $compiler_count compiler/language spec files with LuaCov"
        compiler_status=0
        "$BUSTED" -c -o gtest -v "${compiler_tests[@]}" ||
            compiler_status=$?
        unit_status=0
        "$BUSTED" -c -o gtest -v "${compiler_unit_tests[@]}" ||
            unit_status=$?
        if (( compiler_status != 0 || unit_status != 0 )); then
            echo "compiler test status: main=$compiler_status unit=$unit_status" \
                >&2
            exit 1
        fi
        ;;
    compiler-uncovered)
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]}))
        echo "Running $compiler_count compiler/language spec files" \
            "without LuaCov"
        "$BUSTED" -o gtest -v \
            "${compiler_tests[@]}" "${compiler_unit_tests[@]}"
        ;;
    library-serial)
        echo "Running ${#uncovered_serial_tests[@]} serial tooling/library" \
            "spec files without LuaCov"
        "$BUSTED" -o gtest -v "${uncovered_serial_tests[@]}"
        ;;
    library-uv-fs)
        echo "Running ${#library_uv_fs_tests[@]} uv/timer/fs spec files" \
            "without LuaCov"
        "$BUSTED" -o gtest -v "${library_uv_fs_tests[@]}"
        ;;
    library-net-os)
        echo "Running ${#library_net_os_tests[@]} net/OS spec files" \
            "without LuaCov"
        "$BUSTED" -o gtest -v "${library_net_os_tests[@]}"
        ;;
    macos-canary)
        seed=${2:-}
        if [[ -z $seed ]]; then
            echo "macos-canary requires a reproducible seed" >&2
            exit 2
        fi
        (
            set -e
            temp_dir=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
            catalog="$temp_dir/titan-canary.$$.list"
            manifest="$temp_dir/titan-canary.$$.manifest"
            trap 'rm -f "$catalog" "$manifest"' EXIT

            echo "Running fixed macOS native/tooling canaries without LuaCov"
            "$BUSTED" -o gtest -v \
                spec/canary_spec.lua \
                spec/libuv_shim_spec.lua \
                spec/minicoro_spec.lua

            "$BUSTED" --list -o plainTerminal \
                "${compiler_tests[@]}" "${compiler_unit_tests[@]}" \
                >"$catalog"
            ./lua spec/support/select_canary_tests.lua \
                --percent 5 --seed "$seed" \
                "${compiler_tests[@]}" "${compiler_unit_tests[@]}" \
                <"$catalog" >"$manifest"
            cat "$manifest"
            "$BUSTED" -o gtest -v \
                --helper=spec/support/canary_filter.lua \
                -Xhelper="$manifest" \
                "${compiler_tests[@]}" "${compiler_unit_tests[@]}"
        )
        ;;
    libraries)
        library_count=$((${#uncovered_serial_tests[@]} +
            ${#library_uv_fs_tests[@]} + ${#library_net_os_tests[@]}))
        echo "Running $library_count tooling/library spec files without LuaCov"

        serial_status=0
        "$BUSTED" -o gtest -v "${uncovered_serial_tests[@]}" ||
            serial_status=$?

        log_dir=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
        uv_fs_log="$log_dir/titan-library-uv-fs.$$.log"
        net_os_log="$log_dir/titan-library-net-os.$$.log"

        "$BUSTED" -o gtest -v "${library_uv_fs_tests[@]}" \
            >"$uv_fs_log" 2>&1 &
        uv_fs_pid=$!
        "$BUSTED" -o gtest -v "${library_net_os_tests[@]}" \
            >"$net_os_log" 2>&1 &
        net_os_pid=$!

        uv_fs_status=0
        wait "$uv_fs_pid" || uv_fs_status=$?
        net_os_status=0
        wait "$net_os_pid" || net_os_status=$?

        if [[ ${GITHUB_ACTIONS:-} == true ]]; then
            echo "::group::Library uv/timer/fs worker"
        else
            echo "Library uv/timer/fs worker"
        fi
        cat "$uv_fs_log"
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::endgroup::"; fi
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then
            echo "::group::Library net/OS worker"
        else
            echo "Library net/OS worker"
        fi
        cat "$net_os_log"
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::endgroup::"; fi

        if (( serial_status != 0 || uv_fs_status != 0 ||
                net_os_status != 0 )); then
            echo "library test status: serial=$serial_status " \
                "uv_fs=$uv_fs_status net_os=$net_os_status" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 {compiler|compiler-uncovered|libraries|" \
            "library-serial|library-uv-fs|library-net-os|" \
            "macos-canary [seed]}" >&2
        exit 2
        ;;
esac

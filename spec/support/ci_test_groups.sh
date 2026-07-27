#!/usr/bin/env bash

# Keep compiler/language coverage separate from native/runtime and library
# behavior. LuaCov's debug hook makes repeated checks of large Titan library
# sources expensive, and it does not measure Titan's C runtime implementation.

set -u

if [[ -z ${BUSTED:-} ]]; then
    if [[ -n ${PREFIX:-} && -x $PREFIX/bin/busted ]]; then
        BUSTED=$PREFIX/bin/busted
    elif [[ -x .lua/bin/busted ]]; then
        BUSTED=.lua/bin/busted
    else
        BUSTED=./lua_modules/bin/busted
    fi
fi
group=${1:-}
compiler_tests=()
compiler_core_tests=()
compiler_heavy_tests=()
compiler_unit_tests=()
compiler_isolated_coverage_tests=()
library_serial_tests=()
library_uv_fs_tests=()
library_net_os_tests=()
library_peg_string_tests=()

while IFS= read -r test_file; do
    case "$test_file" in
        spec/driver_spec.lua | \
        spec/foreigntypes_spec.lua | \
        spec/types_spec.lua)
            # Run these tiny module-level tests in a fresh Busted process so
            # their direct unit coverage is independent of Busted's file
            # insulation and compiler modules loaded by earlier specs.
            compiler_unit_tests+=("$test_file")
            ;;
        spec/dense_array_runtime_spec.lua | \
        spec/stdlib/coroutine_spec.lua | \
        spec/stdlib/loadlibglobal_spec.lua | \
        spec/stdlib_installer_spec.lua | \
        spec/lpeglabel_build_spec.lua | \
        spec/libuv_build_spec.lua | \
        spec/minicoro_spec.lua | \
        spec/rockspec_spec.lua)
            # Keep serial native/runtime proofs and suites that mutate or
            # inspect shared root artifacts out of the two workers below.
            library_serial_tests+=("$test_file")
            ;;
        spec/stdlib/uv*_spec.lua | \
        spec/stdlib/timer*_spec.lua | \
        spec/stdlib/fs*_spec.lua)
            library_uv_fs_tests+=("$test_file")
            ;;
        spec/stdlib/net*_spec.lua | \
        spec/stdlib/os*_spec.lua)
            library_net_os_tests+=("$test_file")
            ;;
        spec/stdlib/peg*_spec.lua | \
        spec/stdlib/string*_spec.lua)
            library_peg_string_tests+=("$test_file")
            ;;
        spec/coder/coder_spec.lua | \
        spec/coder/flexible_returns_spec.lua)
            # These broad end-to-end files remain on the heavy worker with the
            # measured C-FFI cohort and isolated static-provider coverage.
            compiler_tests+=("$test_file")
            compiler_heavy_tests+=("$test_file")
            ;;
        spec/cdriver_spec.lua | \
        spec/checker/c_ffi_declaration_compatibility_spec.lua | \
        spec/checker/c_ffi_operators_spec.lua | \
        spec/checker/c_ffi_pointer_conversions_spec.lua | \
        spec/checker/c_ffi_spec.lua | \
        spec/checker/c_ffi_stack_objects_spec.lua | \
        spec/checker/c_ffi_tag_names_spec.lua | \
        spec/checker/c_ffi_target_profile_spec.lua | \
        spec/coder/c_ffi_operators_spec.lua | \
        spec/coder/c_ffi_pointer_conversions_spec.lua | \
        spec/coder/c_ffi_spec.lua | \
        spec/coder/c_ffi_stack_objects_spec.lua | \
        spec/coder/c_ffi_tag_names_spec.lua)
            # These compile-probe and generated-C cases are the measured
            # growth in the covered compiler suite. Keep the cohort explicit
            # instead of moving unrelated cheap parser/semantic unit files.
            compiler_tests+=("$test_file")
            compiler_heavy_tests+=("$test_file")
            ;;
        spec/checker/static_compiled_modules_spec.lua | \
        spec/coder/multi_module_libraries_spec.lua | \
        spec/coder/static_compiled_modules_spec.lua | \
        spec/coder/static_dynamic_facade_spec.lua | \
        spec/coder/static_protocol_mismatch_spec.lua | \
        spec/staticmetadata_spec.lua)
            # Busted's file insulation reloads compiler modules between specs,
            # while LuaCov keeps only the last loaded prototype's line table
            # inside one process. Preserve direct feature coverage by running
            # these files one process at a time on the heavy worker after its
            # shard.
            compiler_isolated_coverage_tests+=("$test_file")
            ;;
        *)
            compiler_tests+=("$test_file")
            compiler_core_tests+=("$test_file")
            ;;
    esac
done < <(find spec -type f -name '*_spec.lua' -print | LC_ALL=C sort)

run_isolated_compiler_coverage() {
    local test_file
    local status=0
    for test_file in "${compiler_isolated_coverage_tests[@]}"; do
        "$BUSTED" -c -o gtest -v "$test_file" || status=$?
    done
    return "$status"
}

case "$group" in
    compiler)
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]} +
            ${#compiler_isolated_coverage_tests[@]}))
        echo "Running $compiler_count compiler/language spec files with LuaCov"
        compiler_status=0
        "$BUSTED" -c -o gtest -v "${compiler_tests[@]}" ||
            compiler_status=$?
        unit_status=0
        "$BUSTED" -c -o gtest -v "${compiler_unit_tests[@]}" ||
            unit_status=$?
        isolated_status=0
        run_isolated_compiler_coverage || isolated_status=$?
        if (( compiler_status != 0 || unit_status != 0 ||
            isolated_status != 0 )); then
            echo "compiler test status: main=$compiler_status " \
                "unit=$unit_status isolated=$isolated_status" >&2
            exit 1
        fi
        ;;
    compiler-core)
        compiler_count=$((${#compiler_core_tests[@]} +
            ${#compiler_unit_tests[@]}))
        echo "Running $compiler_count core compiler/language spec files" \
            "with LuaCov"
        compiler_status=0
        # Keep Busted's per-file environments but reuse one compiler module
        # graph and its immutable foreign-header probe caches. The complete
        # local and macOS groups retain ordinary auto-insulation as an
        # independent state-leak check.
        "$BUSTED" --no-auto-insulate -c -o gtest -v \
            "${compiler_core_tests[@]}" ||
            compiler_status=$?
        unit_status=0
        "$BUSTED" -c -o gtest -v "${compiler_unit_tests[@]}" ||
            unit_status=$?
        if (( compiler_status != 0 || unit_status != 0 )); then
            echo "compiler core test status: main=$compiler_status " \
                "unit=$unit_status" >&2
            exit 1
        fi
        ;;
    compiler-heavy)
        compiler_count=$((${#compiler_heavy_tests[@]} +
            ${#compiler_isolated_coverage_tests[@]}))
        echo "Running $compiler_count heavy compiler/language spec files" \
            "with LuaCov"
        compiler_status=0
        "$BUSTED" -c -o gtest -v "${compiler_heavy_tests[@]}" ||
            compiler_status=$?
        isolated_status=0
        run_isolated_compiler_coverage || isolated_status=$?
        if (( compiler_status != 0 || isolated_status != 0 )); then
            echo "compiler heavy test status: main=$compiler_status " \
                "isolated=$isolated_status" >&2
            exit 1
        fi
        ;;
    compiler-uncovered)
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]} +
            ${#compiler_isolated_coverage_tests[@]}))
        echo "Running $compiler_count compiler/language spec files" \
            "without LuaCov"
        "$BUSTED" -o gtest -v \
            "${compiler_tests[@]}" "${compiler_unit_tests[@]}" \
            "${compiler_isolated_coverage_tests[@]}"
        ;;
    library-serial)
        echo "Running ${#library_serial_tests[@]} serial native/runtime and" \
            "library spec files without LuaCov"
        "$BUSTED" -o gtest -v "${library_serial_tests[@]}"
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
    library-peg-string)
        echo "Running ${#library_peg_string_tests[@]} PEG/string spec files" \
            "without LuaCov"
        "$BUSTED" -o gtest -v "${library_peg_string_tests[@]}"
        ;;
    libraries)
        library_count=$((${#library_serial_tests[@]} +
            ${#library_uv_fs_tests[@]} + ${#library_net_os_tests[@]} +
            ${#library_peg_string_tests[@]}))
        echo "Running $library_count native/runtime and library spec files" \
            "without LuaCov"

        serial_status=0
        "$BUSTED" -o gtest -v "${library_serial_tests[@]}" ||
            serial_status=$?

        log_dir=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
        uv_fs_log="$log_dir/titan-library-uv-fs.$$.log"
        net_os_log="$log_dir/titan-library-net-os.$$.log"
        peg_string_log="$log_dir/titan-library-peg-string.$$.log"

        "$BUSTED" -o gtest -v "${library_uv_fs_tests[@]}" \
            >"$uv_fs_log" 2>&1 &
        uv_fs_pid=$!
        "$BUSTED" -o gtest -v "${library_net_os_tests[@]}" \
            >"$net_os_log" 2>&1 &
        net_os_pid=$!
        "$BUSTED" -o gtest -v "${library_peg_string_tests[@]}" \
            >"$peg_string_log" 2>&1 &
        peg_string_pid=$!

        uv_fs_status=0
        wait "$uv_fs_pid" || uv_fs_status=$?
        net_os_status=0
        wait "$net_os_pid" || net_os_status=$?
        peg_string_status=0
        wait "$peg_string_pid" || peg_string_status=$?

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
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then
            echo "::group::Library PEG/string worker"
        else
            echo "Library PEG/string worker"
        fi
        cat "$peg_string_log"
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::endgroup::"; fi

        if (( serial_status != 0 || uv_fs_status != 0 ||
                net_os_status != 0 || peg_string_status != 0 )); then
            echo "library test status: serial=$serial_status " \
                "uv_fs=$uv_fs_status net_os=$net_os_status " \
                "peg_string=$peg_string_status" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 {compiler|compiler-core|compiler-heavy|" \
            "compiler-uncovered|libraries|library-serial|library-uv-fs|" \
            "library-net-os|library-peg-string}" >&2
        exit 2
        ;;
esac

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
compiler_unit_tests=()
compiler_isolated_coverage_tests=()

while IFS= read -r test_file; do
    case "$test_file" in
        spec/asan_generated_c_context_spec.lua | \
        spec/dense_array_runtime_spec.lua | \
        spec/libuv_build_spec.lua | \
        spec/lpeglabel_build_spec.lua | \
        spec/minicoro_spec.lua | \
        spec/readline_build_spec.lua | \
        spec/rockspec_spec.lua | \
        spec/stdlib_installer_spec.lua)
            # The prepared-tree producer and complete macOS lane run these
            # runtime, packaging, and standard-library specs without LuaCov.
            ;;
        spec/driver_spec.lua | \
        spec/foreigntypes_spec.lua | \
        spec/types_spec.lua)
            # Run these tiny module-level tests in a fresh Busted process so
            # their direct unit coverage is independent of Busted's file
            # insulation and compiler modules loaded by earlier specs.
            compiler_unit_tests+=("$test_file")
            ;;
        spec/union_interface_spec.lua | \
        spec/checker/static_compiled_modules_spec.lua | \
        spec/coder/multi_module_libraries_spec.lua | \
        spec/coder/parallel_compilation_spec.lua | \
        spec/coder/static_compiled_modules_spec.lua | \
        spec/coder/static_dynamic_facade_spec.lua | \
        spec/coder/static_protocol_mismatch_spec.lua | \
        spec/staticmetadata_spec.lua | \
        spec/titanc_parallel_spec.lua)
            # LuaCov keeps only the last loaded compiler prototype's line table
            # inside one process. Exercise these direct prototypes in isolated
            # Busted processes after the complete main compiler set.
            compiler_isolated_coverage_tests+=("$test_file")
            ;;
        *)
            compiler_tests+=("$test_file")
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
    *)
        echo "usage: $0 {compiler|compiler-uncovered}" >&2
        exit 2
        ;;
esac

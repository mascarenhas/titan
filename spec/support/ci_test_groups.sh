#!/usr/bin/env bash

# Keep compiler/language coverage separate from native/runtime and library
# behavior. LuaCov's debug hook makes repeated checks of large Titan library
# sources expensive, and it does not measure Titan's C runtime implementation.

# Bash before 4.4 treats a declared empty array as unset while nounset is
# active. macOS still ships Bash 3.2, and the partition arrays below are
# intentionally empty before their first validated row. Retain nounset on
# shells with the corrected array behavior; every scalar expansion used on the
# older-shell path is initialized here or guarded with a default/error form.
if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    set -u
else
    set +u
fi

export TITAN_BUILD_PROFILE=${TITAN_BUILD_PROFILE-validation}
case $TITAN_BUILD_PROFILE in
    production|validation) ;;
    *) echo 'TITAN_BUILD_PROFILE must be production or validation' >&2; exit 2 ;;
esac

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
requested_shard=
case "$group" in
    compiler | compiler-uncovered)
        ;;
    compiler-shard-[1-4])
        requested_shard=${group##*-}
        ;;
    compiler-uncovered-shard-[1-4])
        requested_shard=${group##*-}
        ;;
    *)
        usage="usage: $0 {compiler|compiler-uncovered|compiler-shard-{1..4}|"
        usage+="compiler-uncovered-shard-{1..4}}"
        echo "$usage" >&2
        exit 2
        ;;
esac

partition_file=spec/support/ci_compiler_test_groups.txt
stress_partition_file=spec/support/ci_compiler_stress_files.txt
partition_files=()
partition_shards=()
partition_seen=()
while read -r shard test_file observed_seconds extra; do
    if [[ -z ${shard:-} || $shard == \#* ]]; then continue; fi
    if [[ ! $shard =~ ^[1-4]$ || -z ${test_file:-} ||
          ! ${observed_seconds:-} =~ ^[0-9]+([.][0-9]+)?$ ||
          -n ${extra:-} ]]; then
        echo "invalid compiler partition row: $shard ${test_file:-} " \
            "${observed_seconds:-} ${extra:-}" >&2
        exit 2
    fi
    for existing in "${partition_files[@]}"; do
        if [[ $existing == "$test_file" ]]; then
            echo "duplicate compiler partition entry: $test_file" >&2
            exit 2
        fi
    done
    partition_files+=("$test_file")
    partition_shards+=("$shard")
done < "$partition_file"

stress_files=()
stress_seen=()
while read -r test_file extra; do
    if [[ -z ${test_file:-} || $test_file == \#* ]]; then continue; fi
    if [[ $test_file != spec/*_spec.lua || -n ${extra:-} ]]; then
        echo "invalid compiler stress row: $test_file ${extra:-}" >&2
        exit 2
    fi
    for existing in "${stress_files[@]}"; do
        if [[ $existing == "$test_file" ]]; then
            echo "duplicate compiler stress entry: $test_file" >&2
            exit 2
        fi
    done
    stress_files+=("$test_file")
done < "$stress_partition_file"

compiler_tests=()
compiler_unit_tests=()
compiler_isolated_coverage_tests=()
compiler_stress_tests=()
compiler_unit_stress_tests=()
compiler_isolated_stress_tests=()
partition_status=0
while IFS= read -r test_file; do
    category=
    case "$test_file" in
        spec/asan_generated_c_context_spec.lua | \
        spec/dense_array_runtime_spec.lua | \
        spec/libuv_build_spec.lua | \
        spec/lpeglabel_build_spec.lua | \
        spec/minicoro_spec.lua | \
        spec/rockspec_spec.lua)
            # The prepared-tree producer and complete macOS lane run these
            # runtime, packaging, and standard-library specs without LuaCov.
            ;;
        spec/driver_spec.lua | \
        spec/foreigntypes_spec.lua | \
        spec/types_spec.lua)
            # Run these tiny module-level tests in a fresh Busted process so
            # their direct unit coverage is independent of Busted's file
            # insulation and compiler modules loaded by earlier specs.
            category=unit
            ;;
        spec/cprobe_cache_spec.lua | \
        spec/cprobe_spec.lua | \
        spec/parser_spec.lua | \
        spec/sha256_spec.lua | \
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
            category=isolated
            ;;
        *)
            category=main
            ;;
    esac

    stress_index=
    for index in "${!stress_files[@]}"; do
        if [[ ${stress_files[$index]} == "$test_file" ]]; then
            stress_index=$index
            stress_seen[$index]=true
            break
        fi
    done
    if [[ -n $category ]]; then
        if grep -q '#stress' "$test_file"; then
            if [[ -z $stress_index ]]; then
                echo "tagged compiler stress spec is missing from " \
                    "$stress_partition_file: $test_file" >&2
                partition_status=1
            fi
        elif [[ -n $stress_index ]]; then
            echo "listed compiler stress spec has no #stress tag: " \
                "$test_file" >&2
            partition_status=1
        fi
    fi

    if [[ -n $category ]]; then
        shard=
        partition_index=
        for index in "${!partition_files[@]}"; do
            if [[ ${partition_files[$index]} == "$test_file" ]]; then
                shard=${partition_shards[$index]}
                partition_index=$index
                break
            fi
        done
        if [[ -z $shard ]]; then
            echo "compiler spec is missing from $partition_file: $test_file" >&2
            partition_status=1
            continue
        fi
        partition_seen[$partition_index]=true
        if [[ -z $requested_shard || $requested_shard == "$shard" ]]; then
            case "$category" in
                main) compiler_tests+=("$test_file") ;;
                unit) compiler_unit_tests+=("$test_file") ;;
                isolated) compiler_isolated_coverage_tests+=("$test_file") ;;
            esac
            if [[ -n $stress_index ]]; then
                case "$category" in
                    main) compiler_stress_tests+=("$test_file") ;;
                    unit) compiler_unit_stress_tests+=("$test_file") ;;
                    isolated)
                        compiler_isolated_stress_tests+=("$test_file")
                        ;;
                esac
            fi
        fi
    elif [[ -n $stress_index ]]; then
        echo "stress spec is outside the compiler/language group: " \
            "$test_file" >&2
        partition_status=1
    fi
done < <(find spec -type f -name '*_spec.lua' -print | LC_ALL=C sort)

for index in "${!partition_files[@]}"; do
    if [[ -z ${partition_seen[$index]-} ]]; then
        echo "stale or excluded compiler partition entry: " \
            "${partition_files[$index]}" >&2
        partition_status=1
    fi
done
for index in "${!stress_files[@]}"; do
    if [[ -z ${stress_seen[$index]-} ]]; then
        echo "stale compiler stress entry: ${stress_files[$index]}" >&2
        partition_status=1
    fi
done
if (( partition_status != 0 )); then exit 2; fi

# These specs deliberately reuse source/header pathnames across independent
# compiler worlds, so production exact-text success markers must not cross
# their test boundaries.
export TITAN_PROBE_CACHE_DISABLE=1

run_isolated_compiler_coverage() {
    local test_file
    local status=0
    for test_file in "${compiler_isolated_coverage_tests[@]}"; do
        "$BUSTED" -c -o gtest -v --exclude-tags=stress "$test_file" ||
            status=$?
    done
    return "$status"
}

run_compiler_coverage() {
    local compiler_status=0
    local unit_status=0
    local isolated_status=0
    local compiler_count=$((${#compiler_tests[@]} +
        ${#compiler_unit_tests[@]} +
        ${#compiler_isolated_coverage_tests[@]}))
    local label=${requested_shard:+ shard $requested_shard}
    echo "Running $compiler_count compiler/language spec files${label}" \
        "with LuaCov"

    if (( ${#compiler_tests[@]} > 0 )); then
        "$BUSTED" -c -o gtest -v --exclude-tags=stress \
            "${compiler_tests[@]}" ||
            compiler_status=$?
    fi
    if (( ${#compiler_unit_tests[@]} > 0 )); then
        "$BUSTED" -c -o gtest -v --exclude-tags=stress \
            "${compiler_unit_tests[@]}" ||
            unit_status=$?
    fi
    run_isolated_compiler_coverage || isolated_status=$?
    if (( compiler_status != 0 || unit_status != 0 ||
        isolated_status != 0 )); then
        echo "compiler test status: main=$compiler_status " \
            "unit=$unit_status isolated=$isolated_status" >&2
        return 1
    fi
}

run_isolated_compiler_stress() {
    local test_file
    local status=0
    for test_file in "${compiler_isolated_stress_tests[@]}"; do
        "$BUSTED" -o gtest -v --tags=stress "$test_file" || status=$?
    done
    return "$status"
}

run_compiler_stress() {
    local compiler_status=0
    local unit_status=0
    local isolated_status=0
    local stress_count=$((${#compiler_stress_tests[@]} +
        ${#compiler_unit_stress_tests[@]} +
        ${#compiler_isolated_stress_tests[@]}))
    local label=${requested_shard:+ shard $requested_shard}
    echo "Running $stress_count compiler stress spec files${label}" \
        "without LuaCov"

    if (( ${#compiler_stress_tests[@]} > 0 )); then
        "$BUSTED" -o gtest -v --tags=stress \
            "${compiler_stress_tests[@]}" || compiler_status=$?
    fi
    if (( ${#compiler_unit_stress_tests[@]} > 0 )); then
        "$BUSTED" -o gtest -v --tags=stress \
            "${compiler_unit_stress_tests[@]}" || unit_status=$?
    fi
    run_isolated_compiler_stress || isolated_status=$?
    if (( compiler_status != 0 || unit_status != 0 ||
        isolated_status != 0 )); then
        echo "compiler stress status: main=$compiler_status " \
            "unit=$unit_status isolated=$isolated_status" >&2
        return 1
    fi
}

case "$group" in
    compiler | compiler-shard-[1-4])
        coverage_status=0
        stress_status=0
        run_compiler_coverage || coverage_status=$?
        run_compiler_stress || stress_status=$?
        if (( coverage_status != 0 || stress_status != 0 )); then
            echo "compiler lane status: coverage=$coverage_status " \
                "stress=$stress_status" >&2
            exit 1
        fi
        ;;
    compiler-uncovered | compiler-uncovered-shard-[1-4])
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]} +
            ${#compiler_isolated_coverage_tests[@]}))
        label=${requested_shard:+ shard $requested_shard}
        echo "Running $compiler_count compiler/language spec files${label}" \
            "without LuaCov"
        "$BUSTED" -o gtest -v \
            "${compiler_tests[@]}" "${compiler_unit_tests[@]}" \
            "${compiler_isolated_coverage_tests[@]}"
        ;;
esac

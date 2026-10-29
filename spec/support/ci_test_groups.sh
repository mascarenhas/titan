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
if [[ -n ${LUA:-} ]]; then
    selector_lua=$LUA
elif [[ -n ${PREFIX:-} && -x $PREFIX/bin/lua ]]; then
    selector_lua=$PREFIX/bin/lua
elif [[ -x .lua/bin/lua ]]; then
    selector_lua=.lua/bin/lua
elif [[ -x ./lua_modules/bin/lua ]]; then
    selector_lua=./lua_modules/bin/lua
else
    selector_lua=lua
fi

group=${1:-}
# An optional phase selects all, only ordinary, or only exclusive files of a
# covered shard; ci_parallel_compiler_tests.sh runs exclusive files alone.
phase=${2:-all}
requested_shard=
requested_domain=compiler
case "$group" in
    compiler)
        ;;
    compiler-uncovered)
        # The complete macOS compiler command retains both domains.
        requested_domain=all
        ;;
    stdlib-compiler | stdlib-compiler-uncovered)
        requested_domain=stdlib
        ;;
    compiler-shard-[1-4])
        requested_shard=${group##*-}
        ;;
    stdlib-compiler-shard-[1-2])
        # One of the stdlib job's two concurrent installed-stdlib halves.
        requested_domain=stdlib
        requested_shard=${group##*-}
        ;;
    *)
        usage="usage: $0 {compiler|compiler-uncovered|compiler-shard-{1..4}|"
        usage+="stdlib-compiler|stdlib-compiler-uncovered|"
        usage+="stdlib-compiler-shard-{1..2}} [all|ordinary|exclusive]"
        echo "$usage" >&2
        exit 2
        ;;
esac
case "$phase" in
    all | ordinary | exclusive) ;;
    *)
        echo "invalid compiler selection phase: $phase" >&2
        exit 2
        ;;
esac

# The Lua LPT helper validates ci_compiler_test_groups.txt,
# ci_stdlib_compiler_test_files.txt, ci_compiler_stress_files.txt, and the
# seven retained runtime/packaging specs:
#   spec/asan_generated_c_context_spec.lua
#   spec/dense_array_runtime_spec.lua
#   spec/libuv_build_spec.lua
#   spec/lpeglabel_build_spec.lua
#   spec/minicoro_spec.lua
#   spec/rockspec_spec.lua
#   spec/titan_install_spec.lua
compiler_tests=()
compiler_unit_tests=()
compiler_isolated_coverage_tests=()
compiler_stress_tests=()
compiler_unit_stress_tests=()
compiler_isolated_stress_tests=()

selection_output=
if ! selection_output=$("$selector_lua" -E spec/support/compiler_test_groups.lua ci-select "$group" "$phase"); then
    exit 2
fi

while IFS=$'\t' read -r category test_file; do
    if [[ -z ${category:-} || -z ${test_file:-} ]]; then continue; fi
    case "$category" in
        main) compiler_tests+=("$test_file") ;;
        unit) compiler_unit_tests+=("$test_file") ;;
        isolated) compiler_isolated_coverage_tests+=("$test_file") ;;
        stress_main) compiler_stress_tests+=("$test_file") ;;
        stress_unit) compiler_unit_stress_tests+=("$test_file") ;;
        stress_isolated) compiler_isolated_stress_tests+=("$test_file") ;;
        *)
            echo "unknown compiler test category: $category $test_file" >&2
            exit 2
            ;;
    esac
done <<< "$selection_output"

# These specs deliberately reuse source/header pathnames across independent
# compiler worlds, so production exact-text success markers must not cross
# their test boundaries.
export TITAN_PROBE_CACHE_DISABLE=1
domain_label=compiler/language
if [[ $requested_domain == stdlib ]]; then
    domain_label="stdlib compiler integration"
fi

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
    echo "Running $compiler_count $domain_label spec files${label}" \
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
    echo "Running $stress_count $domain_label stress spec files${label}" \
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
    compiler | compiler-shard-[1-4] | stdlib-compiler | stdlib-compiler-shard-[1-2])
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
    compiler-uncovered | stdlib-compiler-uncovered)
        compiler_count=$((${#compiler_tests[@]} +
            ${#compiler_unit_tests[@]} +
            ${#compiler_isolated_coverage_tests[@]}))
        echo "Running $compiler_count $domain_label spec files without LuaCov"
        # An empty selection must not fall back to Busted's default spec root.
        if (( compiler_count > 0 )); then
            "$BUSTED" -o gtest -v \
                "${compiler_tests[@]}" "${compiler_unit_tests[@]}" \
                "${compiler_isolated_coverage_tests[@]}"
        fi
        ;;
esac

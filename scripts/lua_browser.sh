#!/bin/sh
#
# Build and install the fork's WebAssembly Lua library (PREFIX/lib/browser)
# with configuration + digest reuse verification.
#
# Reuses an existing installation only when:
#   - the effective browser-config (fork revision, wasi-sdk version, target,
#     sjlj mode, normalized cflags, sorted lua_defines, preprocessed numeric
#     configuration, and Wasm target features) matches the installed record;
#   - all installed headers in PREFIX/lib/browser/include/*.h match both the
#     record's headers_sha256 and the current source headers; and
#   - PREFIX/lib/browser/liblua.a is an intact Wasm archive whose SHA-256
#     matches the record's archive_sha256 (and, when a current build archive
#     exists in lua-5.5.1/src/browser/liblua.a, matches it as well).

set -eu

fail() {
	printf 'lua-browser: %s\n' "$*" >&2
	exit 1
}

trim() {
	printf '%s' "${1# }"
}

prefix=${PREFIX:-}
lua_dir=${LUA_DIR:-lua-5.5.1}
make_cmd=${MAKE:-make}
mycflags=${LUA_BROWSER_MYCFLAGS-${MYCFLAGS-}}
myldflags=${LUA_BROWSER_MYLDFLAGS-${MYLDFLAGS-}}

[ -n "$prefix" ] || fail "PREFIX is required"
[ -f "$lua_dir/src/lua.h" ] || {
	echo "ERROR: Lua source is missing; initialize the Lua submodule." >&2
	echo "Run: git submodule update --init --recursive" >&2
	exit 1
}

# Select the wasi-sdk's sibling tools: LUA_BROWSER_CC when set, else clang in
# WASI_SDK_PATH, else the first clang on PATH that sits in a wasi-sdk bin
# directory, as the compiler's discovery selects it. The fork's Make goals
# check the pinned release named by the sdk's VERSION file.
browser_cc=${LUA_BROWSER_CC-}
browser_ar=${LUA_BROWSER_AR-}
browser_ranlib=${LUA_BROWSER_RANLIB-}
wasi_sdk=${WASI_SDK_PATH-}

tool_suffix=
if [ "${OS:-}" = Windows_NT ]; then
	tool_suffix=.exe
	if [ -n "$browser_cc" ]; then browser_cc=$(printf '%s' "$browser_cc" | tr '\\' /); fi
	if [ -n "$wasi_sdk" ]; then wasi_sdk=$(printf '%s' "$wasi_sdk" | tr '\\' /); fi
fi
clang=clang$tool_suffix
llvm_ar=llvm-ar$tool_suffix
llvm_ranlib=llvm-ranlib$tool_suffix
remedy="install wasi-sdk-34.0 from https://github.com/WebAssembly/wasi-sdk/releases and set WASI_SDK_PATH to its directory"

resolved_cc=
if [ -n "$browser_cc" ]; then
	case $browser_cc in
	*/*) [ -x "$browser_cc" ] && resolved_cc=$browser_cc ;;
	*) resolved_cc=$(command -v "$browser_cc" 2>/dev/null || true) ;;
	esac
elif [ -n "$wasi_sdk" ]; then
	candidate="$wasi_sdk/bin/$clang"
	if [ -x "$candidate" ]; then
		resolved_cc=$candidate
	else
		fail "browser target requires wasi-sdk 34.0: clang not found at \"$candidate\" (WASI_SDK_PATH=\"$WASI_SDK_PATH\"); $remedy"
	fi
else
	# A wasi-sdk clang has a sibling ../VERSION; a host clang earlier on PATH
	# does not, and is passed over.
	saved_ifs=$IFS
	IFS=:
	for entry in $PATH; do
		if [ -x "${entry:-.}/$clang" ] && [ -f "${entry:-.}/../VERSION" ]; then
			resolved_cc=${entry:-.}/$clang
			break
		fi
	done
	IFS=$saved_ifs
	[ -n "$resolved_cc" ] || fail "browser target requires wasi-sdk 34.0: no wasi-sdk clang on PATH (WASI_SDK_PATH is unset, and a wasi-sdk clang has a sibling ../VERSION); $remedy"
fi

if [ -n "$resolved_cc" ]; then
	sdk_bin=$(CDPATH= cd "$(dirname "$resolved_cc")" && pwd)
	if [ -z "$browser_ar" ] && [ ! -x "$sdk_bin/$llvm_ar" ]; then
		fail "browser target requires wasi-sdk 34.0: llvm-ar not found at \"$sdk_bin/$llvm_ar\" (clang=\"$resolved_cc\"); $remedy"
	fi
	if [ -z "$browser_ranlib" ] && [ ! -x "$sdk_bin/$llvm_ranlib" ]; then
		fail "browser target requires wasi-sdk 34.0: llvm-ranlib not found at \"$sdk_bin/$llvm_ranlib\" (clang=\"$resolved_cc\"); $remedy"
	fi
	PATH="$sdk_bin:$PATH"
	export PATH
fi

effective_cc=${browser_cc:-$clang}
effective_ar=${browser_ar:-$llvm_ar rc}
effective_ranlib=${browser_ranlib:-$llvm_ranlib}
if [ "$tool_suffix" = .exe ] && [ -n "$resolved_cc" ]; then
	# The directory is now first on PATH. Pass the basename through the
	# fork's recursive Make command variables without quoting a drive path
	# or any spaces in the tool's parent directories.
	effective_cc=${resolved_cc##*/}
fi

fork_make() {
	if [ "$tool_suffix" = .exe ]; then
		"$make_cmd" SHELL=sh.exe "$@"
	else
		"$make_cmd" "$@"
	fi
}

if command -v sha256sum >/dev/null 2>&1; then
	sha256_file() { sha256sum < "$1" | cut -c1-64; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_file() { shasum -a 256 < "$1" | cut -c1-64; }
elif command -v openssl >/dev/null 2>&1; then
	sha256_file() { openssl dgst -sha256 < "$1" | sed 's/.*= *//' | cut -c1-64; }
else
	fail "no SHA-256 tool found (tried sha256sum, shasum -a 256 and openssl dgst -sha256)"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/titan-lua-browser.XXXXXX") ||
	fail "cannot create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

verify_wasm_archive() {
	ar_file=$1
	[ -f "$ar_file" ] || return 1
	[ "$(head -c 8 "$ar_file" 2>/dev/null || true)" = "!<arch>" ] || return 1
	ar_tmp="$tmp/verify_ar"
	rm -rf "$ar_tmp"
	mkdir -p "$ar_tmp"
	(cd "$ar_tmp" && "${effective_ar%% *}" x "$ar_file") >/dev/null 2>&1 || return 1
	[ -f "$ar_tmp/lapi.o" ] && [ -f "$ar_tmp/linit.o" ] || return 1
	member_count=0
	for obj in "$ar_tmp"/*.o; do
		[ -f "$obj" ] || return 1
		magic=$(od -An -tx1 -N4 "$obj" 2>/dev/null | tr -d ' \t\n')
		[ "$magic" = "0061736d" ] || return 1
		member_count=$((member_count + 1))
	done
	[ "$member_count" -ge 32 ] || return 1
	return 0
}

build_and_install() {
	# Force reconstruction of the archive on fallback rather than trusting ar
	# magic on an existing build-tree liblua.a, and purge any corrupt object.
	rm -f "$lua_dir/src/browser/liblua.a"
	for obj in "$lua_dir/src/browser/obj"/*.o; do
		[ -e "$obj" ] || break
		magic=$(od -An -tx1 -N4 "$obj" 2>/dev/null | tr -d ' \t\n')
		if [ "$magic" != "0061736d" ]; then
			rm -f "$obj"
		fi
	done
	fork_make -C "$lua_dir" install-browser PREFIX="$prefix" \
		FORK_REVISION="${FORK_REVISION-}" \
		BROWSER_CC="$effective_cc" \
		BROWSER_AR="$effective_ar" \
		BROWSER_RANLIB="$effective_ranlib" \
		MYCFLAGS="$mycflags" \
		MYLDFLAGS="$myldflags"
	verify_wasm_archive "$prefix/lib/browser/liblua.a" ||
		fail "installed browser Lua archive failed post-install Wasm verification"
}

check_reuse() {
	dest="$prefix/lib/browser"
	record_file="$dest/liblua-config.txt"
	installed_archive="$dest/liblua.a"
	installed_inc="$dest/include"

	[ -f "$record_file" ] || return 1
	[ -f "$installed_archive" ] || return 1
	[ -d "$installed_inc" ] || return 1

	command -v "$effective_cc" >/dev/null 2>&1 || return 1

	fork_make -s --no-print-directory -C "$lua_dir/src" browser-config \
		BROWSER_CC="$effective_cc" \
		BROWSER_AR="$effective_ar" \
		BROWSER_RANLIB="$effective_ranlib" \
		MYCFLAGS="$mycflags" \
		MYLDFLAGS="$myldflags" >"$tmp/config" 2>/dev/null || return 1

	cfg_archive=
	cfg_src=
	cfg_root=
	cfg_headers=
	cfg_cc=
	cfg_target=
	cfg_wasi_sdk=
	cfg_sjlj=
	cfg_cflags=
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
		browser_archive=*) cfg_archive=$(trim "${line#browser_archive=}") ;;
		browser_src=*) cfg_src=$(trim "${line#browser_src=}") ;;
		browser_root=*) cfg_root=$(trim "${line#browser_root=}") ;;
		browser_headers=*) cfg_headers=$(trim "${line#browser_headers=}") ;;
		browser_cc=*) cfg_cc=$(trim "${line#browser_cc=}") ;;
		browser_target=*) cfg_target=$(trim "${line#browser_target=}") ;;
		browser_wasi_sdk_version=*) cfg_wasi_sdk=$(trim "${line#browser_wasi_sdk_version=}") ;;
		browser_sjlj=*) cfg_sjlj=$(trim "${line#browser_sjlj=}") ;;
		browser_cflags=*) cfg_cflags=$(trim "${line#browser_cflags=}") ;;
		*) return 1 ;;
		esac
	done <"$tmp/config"

	[ -n "$cfg_archive" ] && [ -n "$cfg_headers" ] && [ -n "$cfg_cc" ] &&
		[ -n "$cfg_target" ] && [ -n "$cfg_wasi_sdk" ] &&
		[ -n "$cfg_sjlj" ] && [ -n "$cfg_cflags" ] || return 1

	cc_path=$(command -v "$cfg_cc" 2>/dev/null) || return 1
	found_ver=$(sed -n 1p "${cc_path%/*}/../VERSION" 2>/dev/null || true)
	[ "$found_ver" = "$cfg_wasi_sdk" ] || return 1

	src_abs=$(CDPATH= cd "$lua_dir/src" && pwd)
	root_abs=$(CDPATH= cd "$lua_dir" && pwd)

	revision=${FORK_REVISION:-}
	if [ -z "$revision" ]; then
		[ -e "$root_abs/.git" ] || return 1
		revision=$(git -C "$root_abs" rev-parse HEAD 2>/dev/null || true)
	fi
	case $revision in
	'' | *[!0-9a-f]*) return 1 ;;
	esac
	[ ${#revision} -eq 40 ] || return 1

	# Exactly the target and longjmp spellings the fork's installer and the
	# compiler accept: --target=TRIPLE, -mexception-handling and the two
	# '-mllvm OPTION' pairs. The refused list is the compiler's
	# (browsertarget.validate_flags), as in tools/install-browser.sh.
	cflags_normalized=
	defines=
	flag_target=
	eh=
	backend=
	owned=
	pic_flags=
	previous=
	for flag in $cfg_cflags; do
		cflags_normalized=${cflags_normalized:+$cflags_normalized }$flag
		if [ "$previous" = -mllvm ]; then
			backend="$backend$flag
"
			previous=
			continue
		fi
		case $flag in
		-D*) defines=${defines:+$defines }$flag ;;
		-fPIC | -fpic | -fPIE | -fpie) pic_flags="$pic_flags $flag" ;;
		--target=*) flag_target=${flag#--target=} ;;
		-mexception-handling) eh=1 ;;
		-mllvm=* | -target | -mno-exception-handling | -mlegacy-exception-handling | \
		-mno-legacy-exception-handling | -fwasm-exceptions | -fno-wasm-exceptions | \
		-Xclang* | --config* | @* | -pie | -shared | -dynamiclib | -rdynamic | \
		-pthread | -ffat-lto-objects | -m32 | -m64 | -flto | -flto=* | -march=* | \
		-mcpu=* | -mtune=* | --sysroot* | -mexec-model*)
			owned="$owned $flag" ;;
		esac
		previous=$flag
	done
	[ "$previous" != -mllvm ] || return 1
	backend=$(printf '%s' "$backend" | LC_ALL=C sort | paste -sd ' ' -)
	if [ -n "$defines" ]; then
		lua_defines=$(printf '%s\n' $defines | LC_ALL=C sort -u | paste -sd ' ' -)
	else
		lua_defines=
	fi
	[ -z "$owned" ] && [ "$flag_target" = "$cfg_target" ] || return 1
	[ "$cfg_sjlj" = wasm-exnref ] && [ "$eh" = 1 ] &&
		[ "$backend" = "-wasm-enable-sjlj -wasm-use-legacy-eh=false" ] || return 1
	[ -z "$pic_flags" ] || return 1

	cat >"$tmp/macros.c" <<'EOF'
#include "luaconf.h"
EOF
	macros=$("$cfg_cc" -dM -E -I"$src_abs" $cfg_cflags "$tmp/macros.c" 2>/dev/null) || return 1
	if printf '%s\n' "$macros" | awk '$1 == "#define" && $2 == "LUA_USE_POSIX" { f = 1 } END { exit !f }'; then
		return 1
	fi
	printf '%s\n' "$macros" | awk '$1 == "#define" && $2 == "LUA_USE_BROWSER" { f = 1 } END { exit !f }' || return 1
	if printf '%s\n' "$macros" | awk '$1 == "#define" && $2 == "LUA_USE_DLOPEN" { f = 1 } END { exit !f }'; then
		return 1
	fi

	cat >"$tmp/numeric.c" <<'EOF'
#include "luaconf.h"
lua_probe_integer LUA_INTEGER
lua_probe_number LUA_NUMBER
EOF
	numeric_out=$("$cfg_cc" -E -P -I"$src_abs" $cfg_cflags "$tmp/numeric.c" 2>/dev/null) || return 1
	int_type=$(printf '%s\n' "$numeric_out" | awk '$1 == "lua_probe_integer" { sub(/^[ \t]*lua_probe_integer[ \t]+/, ""); gsub(/[ \t][ \t]*/, " "); print }')
	num_type=$(printf '%s\n' "$numeric_out" | awk '$1 == "lua_probe_number" { sub(/^[ \t]*lua_probe_number[ \t]+/, ""); gsub(/[ \t][ \t]*/, " "); print }')
	[ -n "$int_type" ] && [ -n "$num_type" ] || return 1
	numeric="integer=$int_type,float=$num_type"

	# Parse and validate the installed record with the exact grammar of
	# browsertarget.parse_record: non-empty, valid UTF-8, no NUL or CR bytes,
	# LF-terminated, exact banner on line 1, and only the 10 key=value lines
	# thereafter (no extra comments, blank lines, duplicates, or empty values).
	od -An -v -tu1 "$record_file" 2>/dev/null | awk '
	BEGIN { need = 0; last = -1; count = 0; lead = 0; first_cont = 0 }
	{
		for (i = 1; i <= NF; i++) {
			b = $i + 0
			count++
			last = b
			if (b == 0 || b == 13) exit 1
			if (need > 0) {
				if (b < 128 || b > 191) exit 1
				if (first_cont == 1) {
					if (lead == 224 && b < 160) exit 1
					if (lead == 237 && b > 159) exit 1
					if (lead == 240 && b < 144) exit 1
					if (lead == 244 && b > 143) exit 1
					first_cont = 0
				}
				need--
			} else if (b < 128) {
				continue
			} else if (b >= 194 && b <= 223) {
				need = 1; first_cont = 0
			} else if (b >= 224 && b <= 239) {
				need = 2; lead = b; first_cont = 1
			} else if (b >= 240 && b <= 244) {
				need = 3; lead = b; first_cont = 1
			} else {
				exit 1
			}
		}
	}
	END {
		if (count == 0 || need != 0 || last != 10) exit 1
	}' || return 1

	first_line=$(head -n 1 "$record_file" 2>/dev/null || true)
	[ "$first_line" = "# Lua 5.5.1 browser build record v2" ] || return 1

	tail -n +2 "$record_file" >"$tmp/record_body" || return 1
	rec_fork_revision=
	rec_archive_sha256=
	rec_headers_sha256=
	rec_wasi_sdk_version=
	rec_target=
	rec_wasm_features=
	rec_sjlj=
	rec_lua_defines=
	rec_numeric=
	rec_cflags=
	rec_seen=
	rec_count=0
	while IFS= read -r line; do
		case $line in
		*=*)
			key=${line%%=*}
			val=${line#*=}
			[ -n "$val" ] || return 1
			case " $rec_seen " in
			*" $key "*) return 1 ;;
			esac
			rec_seen="$rec_seen $key"
			rec_count=$((rec_count + 1))
			case $key in
			fork_revision) rec_fork_revision=$val ;;
			archive_sha256) rec_archive_sha256=$val ;;
			headers_sha256) rec_headers_sha256=$val ;;
			wasi_sdk_version) rec_wasi_sdk_version=$val ;;
			target) rec_target=$val ;;
			wasm_features) rec_wasm_features=$val ;;
			sjlj) rec_sjlj=$val ;;
			lua_defines) rec_lua_defines=$val ;;
			numeric) rec_numeric=$val ;;
			cflags) rec_cflags=$val ;;
			*) return 1 ;;
			esac
			;;
		*) return 1 ;;
		esac
	done <"$tmp/record_body"
	[ "$rec_count" -eq 10 ] || return 1

	expected_features="+bulk-memory +bulk-memory-opt +call-indirect-overlong +exception-handling +multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext"
	[ "$rec_fork_revision" = "$revision" ] || return 1
	[ "$rec_wasi_sdk_version" = "$cfg_wasi_sdk" ] || return 1
	[ "$rec_target" = "$cfg_target" ] || return 1
	[ "$rec_wasm_features" = "$expected_features" ] || return 1
	[ "$rec_sjlj" = "$cfg_sjlj" ] || return 1
	[ "$rec_lua_defines" = "$lua_defines" ] || return 1
	[ "$rec_numeric" = "$numeric" ] || return 1
	[ "$rec_cflags" = "$cflags_normalized" ] || return 1

	# Verify installed headers match both the record and the source tree, with no extra headers.
	: >"$tmp/inst_headers.txt"
	: >"$tmp/src_headers.txt"
	expected_count=0
	for header in $cfg_headers; do
		[ -f "$installed_inc/$header" ] || return 1
		[ -f "$src_abs/$header" ] || return 1
		printf '%s %s\n' "$header" "$(sha256_file "$installed_inc/$header")" >>"$tmp/inst_headers.txt"
		printf '%s %s\n' "$header" "$(sha256_file "$src_abs/$header")" >>"$tmp/src_headers.txt"
		expected_count=$((expected_count + 1))
	done
	actual_count=0
	for existing in "$installed_inc"/*.h; do
		[ -e "$existing" ] || break
		actual_count=$((actual_count + 1))
	done
	[ "$actual_count" -eq "$expected_count" ] || return 1

	LC_ALL=C sort "$tmp/inst_headers.txt" >"$tmp/inst_headers.sorted"
	LC_ALL=C sort "$tmp/src_headers.txt" >"$tmp/src_headers.sorted"
	inst_headers_sha256=$(sha256_file "$tmp/inst_headers.sorted")
	src_headers_sha256=$(sha256_file "$tmp/src_headers.sorted")
	[ "$inst_headers_sha256" = "$rec_headers_sha256" ] || return 1
	[ "$inst_headers_sha256" = "$src_headers_sha256" ] || return 1

	# Verify the installed archive magic, SHA-256, and Wasm member integrity.
	inst_archive_sha256=$(sha256_file "$installed_archive")
	[ "$inst_archive_sha256" = "$rec_archive_sha256" ] || return 1
	verify_wasm_archive "$installed_archive" || return 1

	# If the fork's browser build directory exists, verify it is up to date and agrees.
	build_archive="$src_abs/$cfg_archive"
	build_stamp="$src_abs/browser/obj/.build-config"
	if [ -e "$src_abs/browser" ]; then
		[ -f "$build_archive" ] || return 1
		[ -f "$build_stamp" ] || return 1
		[ "$(sha256_file "$build_archive")" = "$inst_archive_sha256" ] || return 1
		for src_file in "$src_abs"/*.c "$src_abs"/*.h; do
			[ "$src_file" -nt "$build_archive" ] && return 1
		done
	fi

	return 0
}

if check_reuse; then
	exit 0
fi

build_and_install

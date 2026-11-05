#!/bin/sh
#
# Build and install the fork's WebAssembly Lua library (PREFIX/lib/browser)
# with configuration + digest reuse verification.
#
# Reuses an existing installation only when:
#   - the effective browser-config (fork revision, Emscripten version, target,
#     sjlj mode, normalized cflags, sorted lua_defines, preprocessed numeric
#     configuration, and Wasm target features) matches the installed record;
#   - all installed headers in PREFIX/lib/browser/include/*.h match both the
#     record's headers_sha256 and the current source headers; and
#   - PREFIX/lib/browser/liblua.a is an intact Wasm archive whose SHA-256
#     matches the record's archive_sha256 (and, when a current build archive
#     exists in lua-5.5.1/src/browser/liblua.a, matches it as well).

set -eu
# Reuse probes run emcc directly before entering the fork's Make/install paths.
unset EMCC_CFLAGS

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

# Select emsdk sibling tools when EMSDK is set or emcc is on PATH.
browser_cc=${LUA_BROWSER_CC-}
browser_ar=${LUA_BROWSER_AR-}
browser_ranlib=${LUA_BROWSER_RANLIB-}

resolved_cc=
if [ -n "$browser_cc" ]; then
	case $browser_cc in
	*/*) [ -x "$browser_cc" ] && resolved_cc=$browser_cc ;;
	*) resolved_cc=$(command -v "$browser_cc" 2>/dev/null || true) ;;
	esac
elif [ -n "${EMSDK:-}" ]; then
	candidate="$EMSDK/upstream/emscripten/emcc"
	if [ -x "$candidate" ]; then
		resolved_cc=$candidate
	else
		fail "browser target requires Emscripten 6.0.13: emcc not found at \"$candidate\" (EMSDK=\"$EMSDK\"); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh"
	fi
else
	resolved_cc=$(command -v emcc 2>/dev/null || true)
fi

if [ -n "$resolved_cc" ]; then
	em_dir=$(CDPATH= cd "$(dirname "$resolved_cc")" && pwd)
	if [ -z "$browser_ar" ] && [ ! -x "$em_dir/emar" ]; then
		fail "browser target requires Emscripten 6.0.13: emar not found at \"$em_dir/emar\" (emcc=\"$resolved_cc\"); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh"
	fi
	if [ -z "$browser_ranlib" ] && [ ! -x "$em_dir/emranlib" ]; then
		fail "browser target requires Emscripten 6.0.13: emranlib not found at \"$em_dir/emranlib\" (emcc=\"$resolved_cc\"); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh"
	fi
	PATH="$em_dir:$PATH"
	export PATH
fi

effective_cc=${browser_cc:-emcc}
effective_ar=${browser_ar:-emar rcu}
effective_ranlib=${browser_ranlib:-emranlib}

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
	"$make_cmd" -C "$lua_dir" install-browser PREFIX="$prefix" \
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

	"$make_cmd" -s --no-print-directory -C "$lua_dir/src" browser-config \
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
	cfg_emscripten=
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
		browser_emscripten_version=*) cfg_emscripten=$(trim "${line#browser_emscripten_version=}") ;;
		browser_sjlj=*) cfg_sjlj=$(trim "${line#browser_sjlj=}") ;;
		browser_cflags=*) cfg_cflags=$(trim "${line#browser_cflags=}") ;;
		*) return 1 ;;
		esac
	done <"$tmp/config"

	[ -n "$cfg_archive" ] && [ -n "$cfg_headers" ] && [ -n "$cfg_cc" ] &&
		[ -n "$cfg_target" ] && [ -n "$cfg_emscripten" ] &&
		[ -n "$cfg_sjlj" ] && [ -n "$cfg_cflags" ] || return 1

	banner=$("$cfg_cc" --version 2>/dev/null | head -n 1 || true)
	found_ver=$(printf '%s\n' "$banner" | sed -n 's/.*) \([0-9][0-9.]*\).*/\1/p')
	[ "$found_ver" = "$cfg_emscripten" ] || return 1

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

	cflags_normalized=
	defines=
	longjmp=
	legacy_exceptions=
	eh_flags=
	pic_flags=
	previous=
	for flag in $cfg_cflags; do
		cflags_normalized=${cflags_normalized:+$cflags_normalized }$flag
		case $flag in
		-D*) defines=${defines:+$defines }$flag ;;
		-fPIC | -fpic | -fPIE | -fpie) pic_flags="$pic_flags $flag" ;;
		-fwasm-exceptions | -fno-wasm-exceptions | -mexception-handling | \
		-mno-exception-handling | -mlegacy-exception-handling | \
		-mno-legacy-exception-handling) eh_flags="$eh_flags $flag" ;;
		esac
		setting=
		case $flag in
		-s?*) setting=${flag#-s} ;;
		*) if [ "$previous" = "-s" ]; then setting=$flag; fi ;;
		esac
		case $setting in
		SUPPORT_LONGJMP | SUPPORT_LONGJMP=1 | NO_SUPPORT_LONGJMP=0) longjmp=emscripten ;;
		SUPPORT_LONGJMP=*) longjmp=${setting#*=} ;;
		NO_SUPPORT_LONGJMP | NO_SUPPORT_LONGJMP=*) longjmp=0 ;;
		WASM_LEGACY_EXCEPTIONS | WASM_LEGACY_EXCEPTIONS=1 | \
		NO_WASM_LEGACY_EXCEPTIONS=0) legacy_exceptions=1 ;;
		WASM_LEGACY_EXCEPTIONS=*) legacy_exceptions=${setting#*=} ;;
		NO_WASM_LEGACY_EXCEPTIONS | NO_WASM_LEGACY_EXCEPTIONS=*) legacy_exceptions=0 ;;
		esac
		previous=$flag
	done
	if [ -n "$defines" ]; then
		lua_defines=$(printf '%s\n' $defines | LC_ALL=C sort -u | paste -sd ' ' -)
	else
		lua_defines=
	fi
	[ "$cfg_sjlj" = wasm ] && [ "$legacy_exceptions" = 1 ] || return 1
	[ -z "$eh_flags" ] || return 1
	[ "$longjmp" = "$cfg_sjlj" ] || return 1
	[ -z "$pic_flags" ] || return 1

	cat >"$tmp/macros.c" <<'EOF'
#include "luaconf.h"
EOF
	macros=$("$cfg_cc" -dM -E -I"$src_abs" $cfg_cflags "$tmp/macros.c" 2>/dev/null) || return 1
	printf '%s\n' "$macros" | awk '$1 == "#define" && $2 == "LUA_USE_POSIX" { f = 1 } END { exit !f }' || return 1
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
	[ "$first_line" = "# Lua 5.5.1 browser build record v1" ] || return 1

	tail -n +2 "$record_file" >"$tmp/record_body" || return 1
	rec_fork_revision=
	rec_archive_sha256=
	rec_headers_sha256=
	rec_emscripten_version=
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
			emscripten_version) rec_emscripten_version=$val ;;
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
	[ "$rec_emscripten_version" = "$cfg_emscripten" ] || return 1
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

#!/usr/bin/env bash
# Run from the Titan repository with PREFIX pointing to a prepared Lua/LuaRocks SDK.
# The argument must not exist. Retain it and the exact commands as a smoke receipt.
set -euxo pipefail
case ${1-} in /*) workspace=$1 ;; *) echo 'usage: titan_module_rock_smoke.sh ABSENT_ABSOLUTE_WORKSPACE' >&2; exit 2 ;; esac
lua_prefix=${PREFIX:?select a prepared Lua 5.5 SDK}
mkdir "$workspace"
sdk=$workspace/sdk
mkdir "$sdk"
rockspec=$PWD/titan-0.6.0-1.rockspec
lr() { "$lua_prefix/bin/luarocks" --lua-version 5.5 --lua-dir "$lua_prefix" --tree "$sdk" "$@"; }
# The selected tree is empty. This installs the actual Titan rock there;
# its prepared Lua prefix provides the already installed compiler dependencies.
lr make "$rockspec" --deps-mode=none
# Native library publication validates the DSO with the SDK's bin/lua.
ln -s "$lua_prefix/bin/lua" "$sdk/bin/lua"
export PATH="$sdk/bin:$lua_prefix/bin:$PATH"
export TITAN_ROOT=$sdk
unset TITAN_PATH TITAN_PATH_0_6 LUA_INIT LUA_INIT_5_5 LUA_PATH LUA_PATH_5_5 LUA_CPATH LUA_CPATH_5_5
[[ $(command -v titanc) == "$sdk/bin/titanc" ]]
[[ $(titanc --print-root) == "$sdk" ]]
[[ $(command -v titan-install) == "$sdk/bin/titan-install" ]]
[[ $(command -v titan-uninstall) == "$sdk/bin/titan-uninstall" ]]
lib=$sdk/lib/titan/0.6
rocks=$sdk/lib/luarocks/rocks-5.5
if command -v sha256sum >/dev/null; then hash=(sha256sum); else hash=(shasum -a 256); fi
printf 'keep this header\n' > "$sdk/include/test-unrelated.h"
printf 'keep this library\n' > "$lib/test-unrelated.txt"
"${hash[@]}" "$sdk/include/titan.h" "$sdk/include/test-unrelated.h" "$lib/titan.so" \
    "$lib/titan.a" "$lib/libtitan.a" "$lib/test-unrelated.txt" > "$workspace/sdk.before"

mkdir -p "$workspace/native-author/src" "$workspace/archive" "$workspace/consumer"
cat > "$workspace/native-author/src/cui.titan" <<'TITAN'
function answer(): integer
    return 40
end
TITAN
cat > "$workspace/native-author/titan-cui-0.1.0-1.rockspec" <<'ROCKSPEC'
rockspec_format = "3.0"
package = "titan-cui"
version = "0.1.0-1"
source = { url = "file:///unused-by-make" }
description = { license = "MIT" }
dependencies = { "titan == 0.6.0-1" }
hooks = { post_install = '"$(SCRIPTS_DIR)/titan-install" --path "$(PREFIX)"' }
build = {
    type = "command",
    build_command = 'titanc -q --tree src --output build cui',
    install_command = 'mkdir -p dist/modules && cp build/cui.so build/cui.a dist/modules/',
    copy_directories = { "dist" },
}
ROCKSPEC
(cd "$workspace/native-author" && lr make --deps-mode=none)
[[ -f $lib/cui.so && -f $lib/cui.a ]]
(cd "$workspace/archive" && lr pack titan-cui 0.1.0-1)
# LuaRocks labels this custom dist payload .all.rock; it is a local native
# fixture, NOT a portable distribution artifact.
packed=("$workspace/archive"/titan-cui-0.1.0-1.*.rock)
[[ ${#packed[@]} -eq 1 && -f ${packed[0]} ]]
(cd "$workspace/consumer" && titan-uninstall titan-cui 0.1.0-1)
[[ ! -e $rocks/titan-cui/0.1.0-1 && ! -e $lib/cui.so && ! -e $lib/cui.a ]]
mv "$workspace/native-author" "$workspace/native-author-hidden"
(cd "$workspace/consumer" && lr install "${packed[0]}" --deps-mode=none)
cmp "$rocks/titan-cui/0.1.0-1/dist/modules/cui.so" "$lib/cui.so"
cmp "$rocks/titan-cui/0.1.0-1/dist/modules/cui.a" "$lib/cui.a"

mkdir -p "$workspace/source-author/source-addon/src/addon/bonus"
cat > "$workspace/source-author/source-addon/src/addon/bonus/bonus.titan" <<'TITAN'
function answer(): integer
    return value()
end
TITAN
cat > "$workspace/source-author/source-addon/src/addon/bonus/detail.titan" <<'TITAN'
local function value(): integer
    return 2
end
TITAN
(cd "$workspace/source-author" && tar -czf "$workspace/archive/source-addon.tar.gz" source-addon)
cat > "$workspace/archive/titan-source-addon-0.1.0-1.rockspec" <<ROCKSPEC
rockspec_format = "3.0"
package = "titan-source-addon"
version = "0.1.0-1"
source = { url = "file://$workspace/archive/source-addon.tar.gz", dir = "source-addon" }
description = { license = "MIT" }
dependencies = { "titan == 0.6.0-1" }
hooks = { post_install = '"\$(SCRIPTS_DIR)/titan-install" --path "\$(PREFIX)"' }
build = {
    type = "command",
    install_command = 'mkdir -p dist/modules && cp -R src/. dist/modules/',
    copy_directories = { "dist" },
}
ROCKSPEC
(cd "$workspace/archive" && lr pack titan-source-addon-0.1.0-1.rockspec)
(cd "$workspace/consumer" && lr install "$workspace/archive/titan-source-addon-0.1.0-1.src.rock" --deps-mode=none)
"${hash[@]}" "$lib/addon/bonus/bonus.titan" "$lib/addon/bonus/detail.titan" > "$workspace/addon.before"
cat > "$workspace/consumer/check.titan" <<'TITAN'
local cui = import "cui"
local bonus = import "addon.bonus"
local math = import "math"

function main(args: {string}): integer
    if math.abs(cui.answer() + bonus.answer()) == 42 then return 0 end
    return 1
end
TITAN
(
    cd "$workspace/consumer"
    if titanc -q check > missing-output.log 2>&1; then exit 1; fi
    grep -F "installed source module 'addon.bonus' requires --output DIR" missing-output.log
    titanc -q --output dynamic check
    grep -F '"cui.so"' dynamic/check.c
    ./dynamic/check
    titanc -q --tree . --output archive --static check
    ! grep -F '"cui.so"' archive/check.c
    ./archive/check
    [[ ! -e $lib/.titan-build.lock && ! -e $lib/addon/bonus/bonus.o ]]

    titan-uninstall titan-cui 0.1.0-1
    [[ ! -e $rocks/titan-cui/0.1.0-1 && ! -e $lib/cui.so && ! -e $lib/cui.a ]]
    if titanc -q --output unavailable check > missing-provider.log 2>&1; then exit 1; fi
    grep -F "module 'cui' not found" missing-provider.log
    "${hash[@]}" "$lib/addon/bonus/bonus.titan" "$lib/addon/bonus/detail.titan" > "$workspace/addon.after"
    cmp "$workspace/addon.before" "$workspace/addon.after"
    cat > survivor.titan <<'TITAN'
local bonus = import "addon.bonus"
local math = import "math"

function main(args: {string}): integer
    if math.abs(bonus.answer()) == 2 then return 0 end
    return 1
end
TITAN
    titanc -q --output surviving survivor
    ./surviving/survivor
    lr remove titan-source-addon 0.1.0-1
    [[ ! -e $rocks/titan-source-addon/0.1.0-1 && -f $lib/addon/bonus/bonus.titan ]]
    titan-uninstall titan-source-addon
    titan-uninstall titan-source-addon 0.1.0-1
    [[ ! -e $lib/addon && ! -e $lib/.module-rocks ]]
)
"${hash[@]}" "$sdk/include/titan.h" "$sdk/include/test-unrelated.h" "$lib/titan.so" \
    "$lib/titan.a" "$lib/libtitan.a" "$lib/test-unrelated.txt" > "$workspace/sdk.after"
cmp "$workspace/sdk.before" "$workspace/sdk.after"
printf '%s\n' 'PASS: fresh SDK, local binary/source rocks, compile/run, exact and recovery cleanup'

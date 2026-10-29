#!/bin/sh

# Titan's Lua derives its default paths from the real directory of its own
# executable, so the prefix is the parent of that directory for the Lua 5.5
# found on PATH. -E keeps user startup code out of this build decision.
lua_command=$(command -v lua 2>/dev/null) || exit 0
"$lua_command" -E -e 'if _VERSION ~= "Lua 5.5" then os.exit(1) end' \
  >/dev/null 2>&1 || exit 0

# Follow a launch symlink chain to the interpreter itself.
lua_path=$lua_command
while test -L "$lua_path"; do
  target=$(readlink "$lua_path") || exit 0
  case "$target" in
    /*) lua_path=$target ;;
    *) lua_path=${lua_path%/*}/$target ;;
  esac
done
case "$lua_path" in
  */*) ;;
  *) exit 0 ;;
esac
lua_dir=$(CDPATH= cd "${lua_path%/*}" 2>/dev/null && pwd -P) || exit 0
lua_prefix=$(CDPATH= cd "$lua_dir/.." 2>/dev/null && pwd -P) || exit 0

# Preserve an equivalent spelling supplied by PATH (for example /home when
# it links to /var/home), so it agrees with the original LuaRocks prefix.
# A launcher elsewhere must instead use the interpreter's physical root.
case "$lua_command" in
  */bin/lua)
    path_prefix=${lua_command%/bin/lua}
    test -n "$path_prefix" || path_prefix=/
    physical_prefix=$(CDPATH= cd "$path_prefix" 2>/dev/null && pwd -P)
    if test "$physical_prefix" = "$lua_prefix"; then
      lua_prefix=$path_prefix
    fi
    ;;
esac

printf '%s\n' "$lua_prefix"

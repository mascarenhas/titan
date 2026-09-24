#!/bin/sh

# Ask the PATH interpreter for its own default paths. Titan's Lua resolves
# these from the executable, including when launched through a symlink. -E
# keeps user startup code and Lua path overrides out of this build decision.
lua_command=$(command -v lua 2>/dev/null) || exit 0
lua_prefix=$("$lua_command" -E -e '
if _VERSION ~= "Lua 5.5" then return end
for template in package.cpath:gmatch("[^;]+") do
  local root = template:match("^(.*)/lib/titan/%d+%.%d+/%?%.so$")
  if root and (root == "" or root:sub(1, 1) == "/") then
    io.write(root ~= "" and root or "/")
    return
  end
end
' 2>/dev/null) || exit 0
test -n "$lua_prefix" || exit 0

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

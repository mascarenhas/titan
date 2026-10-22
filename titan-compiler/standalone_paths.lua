-- Embedded by the standalone entrypoint; uses only Lua's built-in libraries.
-- Each explicit path retains Lua/runtime environment precedence, including "".
-- Implementation notes: doc/implementation/driver.md#standalone-startup-path-discovery
return [=[
local directory, version, root_key, path_key = ...
local windows = package.config:sub(1, 1) == "\\"
local extension = windows and ".dll" or ".so"
local inherited_path, inherited_cpath = package.path, package.cpath
-- Return an explicit value, preferring the versioned name.
local function explicit(name, suffix)
    local value = os.getenv(name .. suffix)
    if value == nil then value = os.getenv(name) end
    return value
end
local lua_path = explicit("LUA_PATH", "_5_5") ~= nil
local lua_cpath = explicit("LUA_CPATH", "_5_5") ~= nil
local titan_path = explicit("TITAN_PATH", "_" .. version:gsub("%.", "_"))
if lua_path and lua_cpath and titan_path then return end

local function query(command)
    local ok, pipe = pcall(io.popen,
        command .. (windows and " 2>NUL" or " 2>/dev/null"), "r")
    if not ok or not pipe then return end
    local output = pipe:read("*a")
    local success = pipe:close()
    if success and type(output) == "string" then return output:gsub("[\r\n]+$", "") end
end
local function absolute(root)
    return root and root ~= "" and not root:find("[\r\n;?]") and
        (root:sub(1, 1) == "/" or
         (windows and (root:match("^%a:[/\\]") or root:match("^\\\\"))))
end
local function cpath_root(cpath)
    if not cpath then return end
    cpath = cpath:gsub("\\", "/")
    for _, suffix in ipairs({ "/lib/titan/" .. version .. "/?" .. extension,
                              "/lib/lua/5.5/?" .. extension }) do
        for entry in cpath:gmatch("[^;]+") do
            if entry:sub(-#suffix) == suffix then
                local root = entry:sub(1, -#suffix - 1)
                if root == "" then root = "/" end
                if absolute(root) then return root end
            end
        end
    end
end
local root = query("titanc --print-root")
if not absolute(root) then
    root = cpath_root(query('lua -e "io.write(package.cpath)"'))
end
root = root or directory
-- An explicit Lua C path remains the runtime root source when it has an anchor.
if lua_cpath then root = cpath_root(package.cpath) or root end
-- A trailing separator is retained only for a filesystem root.
local base = root:gsub("[/\\]+$", "")
local function rooted(suffix) return base .. suffix end
if not lua_path then
    package.path = rooted("/share/lua/5.5/?.lua;") ..
        rooted("/share/lua/5.5/?/init.lua;") ..
        rooted("/lib/lua/5.5/?.lua;") ..
        rooted("/lib/lua/5.5/?/init.lua;") .. "./?.lua;./?/init.lua"
end
if not lua_cpath then
    package.cpath = rooted("/lib/titan/" .. version .. "/?" .. extension .. ";") ..
        rooted("/lib/lua/5.5/?" .. extension .. ";") ..
        rooted("/lib/lua/5.5/loadall" .. extension .. ";") .. "./?" .. extension
end
local registry = debug.getregistry()
registry[root_key] = root
-- A Windows launcher also owns a DLL under its adjacent ../lib tree. Keep
-- that distribution available after discovery, even without titanc or Lua.
if windows then
    if not lua_path then
        package.path = package.path .. ";" .. inherited_path
    end
    if not lua_cpath then
        package.cpath = package.cpath .. ";" .. inherited_cpath
    end
    -- The default Titan path names that tree too. As in titan.c's pushpath,
    -- ";;" in an explicit path inserts this same default.
    local default = ".;" .. rooted("/lib/titan/" .. version) .. ";" ..
        directory .. "/../lib/titan/" .. version
    registry[path_key] = titan_path and
        (titan_path:gsub(";;", ";\1;"):gsub("\1", function() return default end)) or
        default
end
]=]

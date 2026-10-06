-- Reconcile optimized native Lua dependencies without changing the O0 CFLAGS
-- used by LuaRocks' Titan build/post-install bridge. This runs before titanc is
-- installed, so it depends only on the prepared Lua and LuaRocks programs.
local prefix, receipt, rocks_receipt, lua_receipt, cc, ar, ranlib, cflags, ldflags,
    parser_cflags, parser_ldflags, parser_version = ...
assert(prefix and parser_version, "missing compiler dependency inputs")
local directory = assert(arg[0]:match("^(.*)/[^/]+$"))
local sha256 = dofile(directory .. "/../titan-compiler/sha256.lua")

local function quote(value)
    assert(not value:find("%z"), "NUL in shell argument")
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function command(arguments)
    local words = {}
    for index, value in ipairs(arguments) do words[index] = quote(value) end
    return table.concat(words, " ")
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local rocks = prefix .. "/bin/luarocks"
local function installed_version(name)
    local pipe = assert(io.popen(command({rocks, "show", "--mversion", name}) ..
        " 2>/dev/null", "r"))
    local version = pipe:read("*a"):match("^%s*(.-)%s*$")
    local ok = pipe:close()
    if ok and version ~= "" then return version end
end

local modules = {
    {rock = "lpeglabel", module = "lpeglabel", version = parser_version,
        cflags = parser_cflags, ldflags = parser_ldflags},
    {rock = "luafilesystem", module = "lfs", minimum = {1, 7, 0},
        cflags = cflags, ldflags = ldflags},
}
local function compatible(module, version)
    if not version then return false end
    if module.version then return version == module.version end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)%-[0-9]+$")
    if not major then return false end
    for index, value in ipairs({tonumber(major), tonumber(minor), tonumber(patch)}) do
        if value ~= module.minimum[index] then
            return value > module.minimum[index]
        end
    end
    return true
end
local abi = assert(_VERSION:match("Lua (.+)"))
local module_path = prefix .. "/lib/lua/" .. abi .. "/?.so"
local function state()
    local rows = {
        "policy=optimized-compiler-dependencies-v1",
        "prefix=" .. prefix, "lua=" .. _VERSION,
        "cc=" .. cc, "ar=" .. ar, "ranlib=" .. ranlib,
        "luarocks=" .. sha256.hex(assert(read(rocks_receipt))),
        "lua-build=" .. sha256.hex(assert(read(lua_receipt))),
    }
    local complete = true
    for _, module in ipairs(modules) do
        local version = installed_version(module.rock)
        local path = package.searchpath(module.module, module_path)
        local bytes = path and read(path)
        if not version or not bytes or #bytes == 0 or
                not compatible(module, version) then
            complete = false
        end
        rows[#rows + 1] = module.rock .. ":version=" .. (version or "")
        rows[#rows + 1] = module.rock .. ":cflags=" .. module.cflags
        rows[#rows + 1] = module.rock .. ":ldflags=" .. module.ldflags
        rows[#rows + 1] = module.rock .. ":module=" .. (path or "")
        rows[#rows + 1] = module.rock .. ":sha256=" ..
            (bytes and sha256.hex(bytes) or "")
    end
    return table.concat(rows, "\n") .. "\n", complete
end

local wanted, complete = state()
if complete and read(receipt) == wanted then return end
for _, module in ipairs(modules) do
    -- Keep an existing compatible filesystem dependency's selected version;
    -- a fresh prefix resolves it normally. LPegLabel shares the audited pin.
    local version = module.version or installed_version(module.rock)
    if not compatible(module, version) then version = nil end
    local arguments = {rocks, "build", module.rock}
    if version then arguments[#arguments + 1] = version end
    for _, value in ipairs({"--force", "CC=" .. cc, "LD=" .. cc,
            "AR=" .. ar, "RANLIB=" .. ranlib,
            "CFLAGS=" .. module.cflags, "LDFLAGS=" .. module.ldflags}) do
        arguments[#arguments + 1] = value
    end
    io.stderr:write("==> Preparing optimized compiler dependency ",
        module.rock, "\n")
    local ok, why, code = os.execute(command(arguments))
    assert(ok, module.rock .. " installation failed (" .. tostring(why) ..
        ": " .. tostring(code) .. ")")
end
wanted, complete = state()
assert(complete, "compiler dependency installation did not produce both modules")
local temporary = receipt .. ".tmp"
local file = assert(io.open(temporary, "wb"))
assert(file:write(wanted))
assert(file:close())
assert(os.rename(temporary, receipt))

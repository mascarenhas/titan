local lfs = require "lfs"
local assert = require "luassert"

local M = {}
local REPO = lfs.currentdir()

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function run(command, cwd)
    if cwd then command = "cd " .. quote(cwd) .. " && " .. command end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, _, status = pipe:close()
    return ok == true or status == 0, status or 0, output
end
M.run = run

local function exists(path)
    return lfs.attributes(path) ~= nil
end

local function host_lua()
    local prefix = os.getenv("PREFIX")
    if prefix and exists(prefix .. "/bin/lua") then
        return prefix .. "/bin/lua"
    end
    if exists(REPO .. "/.lua/bin/lua") then
        return REPO .. "/.lua/bin/lua"
    end
    return REPO .. "/lua"
end

local function fresh_workspace_path(label)
    local path = os.tmpname() .. "-titan-async-stdlib-" .. label
    os.remove(path)
    return path
end

local function find_standard_dir()
    local paths = { REPO .. "/titan" }
    local prefix = os.getenv("PREFIX")
    if prefix and prefix ~= "" then
        paths[#paths + 1] = prefix .. "/lib/titan/0.11/titan"
    end
    for _, path in ipairs(paths) do
        if exists(path .. "/coroutine.so") and exists(path .. "/uv.so") and
                exists(path .. "/timer.so") then
            return path
        end
    end
    error("async stdlib specs require prebuilt coroutine.so, uv.so, and " ..
          "timer.so; " ..
          "run the focused Makefile stdlib target first", 0)
end
M.standard_dir = find_standard_dir

local function module_root(stdlib)
    local parent = stdlib:match("^(.*)/titan$")
    assert.truthy(parent,
        "canonical standard directory must end in /titan: " .. stdlib)
    return parent
end
M.module_root = module_root

local function canonical_cpath(stdlib)
    return module_root(stdlib) .. "/?.so"
end
M.canonical_cpath = canonical_cpath

local function host_libuv_config()
    local makefile = M.read and M.read("Makefile") or nil
    if not makefile then
        local input = assert(io.open(REPO .. "/Makefile", "rb"))
        makefile = input:read("*a")
        input:close()
    end
    local version = assert(makefile:match(
        "LIBUV_VERSION%s*:=%s*([%w%.%-]+)"))
    local include = REPO .. "/libuv-v" .. version .. "/include"
    local archive = REPO .. "/libuv-build/libuv.a"
    assert.truthy(exists(include .. "/uv.h"), "run make libuv first")
    assert.truthy(exists(archive), "run make libuv first")
    local pipe = assert(io.popen("uname -s"))
    local host = assert(pipe:read("*l"))
    assert.truthy(pipe:close())
    local cppflags = "-I" .. include
    local ldflags = "-lpthread"
    if host == "Linux" then
        cppflags = cppflags .. " -D_GNU_SOURCE"
        ldflags = ldflags .. " -ldl -lrt"
    end
    return cppflags, ldflags, archive
end
M.host_libuv_config = host_libuv_config

local function copy_file(source, destination)
    local input = assert(io.open(source, "rb"))
    local contents = input:read("*a")
    input:close()
    local output = assert(io.open(destination, "wb"))
    output:write(contents)
    output:close()
end

local function make_directory(path)
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents)
    local output = assert(io.open(path, "wb"))
    assert.truthy(output:write(contents))
    assert.truthy(output:close())
end

function M.workspace(label)
    local path = fresh_workspace_path(label)
    assert.truthy(lfs.mkdir(path))
    assert.truthy(lfs.mkdir(path .. "/src"))
    -- A private, timestamp-preserving runtime copy keeps the archive current
    -- while preventing concurrent specs from rebuilding the shared checkout.
    local ok, _, output = run("cp -Rp " .. quote(REPO .. "/titan-runtime") ..
        " " .. quote(path .. "/titan-runtime"))
    assert.truthy(ok, output)
    return path
end

function M.write_source(workspace, modname, source)
    local path = workspace .. "/src/" .. modname:gsub("%.", "/") ..
        ".titan"
    make_directory(assert(path:match("^(.+)/[^/]+$")))
    write_file(path, source)
    return path
end

function M.compile(workspace, modname, options)
    options = options or {}
    local stdlib = options.stdlib or find_standard_dir()
    local lua = host_lua()
    local environment = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5 CCACHE_DISABLE=1",
        "TITAN_PATH_0_11=" .. quote(module_root(stdlib)),
        "TITAN_PATH=",
    }
    if options.cppflags then
        environment[#environment + 1] =
            "TITAN_EXTRA_CPPFLAGS=" .. quote(options.cppflags)
    end
    local sanitizer_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local cflags = options.cflags or ""
    if #sanitizer_cflags > 0 then
        if #cflags > 0 then cflags = cflags .. " " end
        cflags = cflags .. sanitizer_cflags
    end
    if #cflags > 0 then
        environment[#environment + 1] =
            "TITAN_EXTRA_CFLAGS=" .. quote(cflags)
    end
    local sanitizer_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local ldflags = options.ldflags or ""
    if #sanitizer_ldflags > 0 then
        if #ldflags > 0 then ldflags = ldflags .. " " end
        ldflags = ldflags .. sanitizer_ldflags
    end
    if #ldflags > 0 then
        environment[#environment + 1] =
            "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags)
    end
    local command = {
        table.concat(environment, " "),
        quote(lua), quote(REPO .. "/spec/support/async_stdlib_compile.lua"),
        quote(REPO), quote(workspace .. "/src"), quote(modname),
        quote(workspace .. "/titan-runtime"),
    }
    for _, object in ipairs(options.extra_objects or {}) do
        command[#command + 1] = quote(object)
    end
    local ok, _, output = run(table.concat(command, " "), workspace)
    assert.truthy(ok, output)
end

local function build_variant_workspace(transformer)
    local workspace = M.workspace("variant")
    assert.truthy(lfs.mkdir(workspace .. "/titan"))
    make_directory(workspace .. "/src/titan")
    local transform = transformer
    if transform:sub(1, 1) ~= "/" then transform = REPO .. "/" .. transform end
    local raw_lua = host_lua()
    local ok, _, output = run(table.concat({
        quote(raw_lua), quote(transform), quote(REPO .. "/titan/uv.titan"),
        quote(workspace .. "/src/titan/uv.titan"),
    }, " "), workspace)
    assert.truthy(ok, output)
    copy_file(REPO .. "/titan/timer.titan",
        workspace .. "/src/titan/timer.titan")
    copy_file(REPO .. "/titan/coroutine.titan",
        workspace .. "/src/titan/coroutine.titan")

    assert.truthy(exists(workspace .. "/titan-runtime/libtitan.a"),
        "async stdlib variant requires make runtime's libtitan.a")
    local variant_stdlib = workspace .. "/titan"
    M.compile(workspace, "titan.coroutine", {
        stdlib = variant_stdlib,
        cppflags = "",
    })

    local cppflags, ldflags, archive = host_libuv_config()
    ldflags = archive .. " " .. ldflags
    M.compile(workspace, "titan.uv", {
        stdlib = variant_stdlib,
        cppflags = cppflags,
        cflags = "-fno-strict-aliasing",
        ldflags = ldflags,
    })
    M.compile(workspace, "titan.timer", {
        stdlib = variant_stdlib,
        cppflags = "",
    })
    return workspace
end

function M.variant_workspace(transformer)
    return build_variant_workspace(transformer)
end

function M.run_lua_source(workspace, source, options)
    options = options or {}
    local stdlib = options.stdlib or find_standard_dir()
    local root = module_root(stdlib)
    local cpath = workspace .. "/?.so;" .. root .. "/?.so;;"
    local lua_path = REPO .. "/?.lua;" .. REPO .. "/?/init.lua;;"
    local lua = host_lua()
    local command = table.concat({
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
        "TITAN_PATH_0_11=" .. quote(root),
        "TITAN_PATH=",
        "LUA_PATH=" .. quote(lua_path),
        "LUA_PATH_5_5=" .. quote(lua_path),
        "LUA_CPATH=" .. quote(cpath),
        "LUA_CPATH_5_5=" .. quote(cpath),
        quote(lua), "-e", quote(source),
    }, " ")
    return run(command, options.cwd or workspace)
end

local function app_command(workspace, modname)
    local stdlib = find_standard_dir()
    return "env -u LUA_PATH -u LUA_CPATH" ..
        " -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
        " TITAN_PATH_0_11=" .. quote(module_root(stdlib)) .. " " ..
        "TITAN_PATH= " .. quote(workspace .. "/" .. modname)
end

function M.run_app(workspace, modname, ...)
    local command = { app_command(workspace, modname) }
    for _, argument in ipairs({ ... }) do
        command[#command + 1] = quote(argument)
    end
    return run(table.concat(command, " "), workspace)
end

function M.read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

function M.cleanup(workspace)
    if workspace then run("rm -rf " .. quote(workspace)) end
end

M.repo = REPO
return M

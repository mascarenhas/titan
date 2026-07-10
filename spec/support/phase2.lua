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

local function find_standard_dir()
    for _, path in ipairs({
        REPO,
        REPO .. "/lua_modules/lib/lua/5.5/titan/stdlib_0_11",
    }) do
        if exists(path .. "/coroutine.so") and exists(path .. "/uv.so") and
                exists(path .. "/timer.so") then
            return path
        end
    end
    error("Phase 2 specs require prebuilt coroutine.so, uv.so, and timer.so; " ..
          "run the focused Makefile stdlib target first", 0)
end
M.standard_dir = find_standard_dir

local function find_alias_template()
    for _, template in ipairs({
        REPO .. "/?.so",
        REPO .. "/lua_modules/lib/lua/5.5/?.so",
    }) do
        local root = template:gsub("%?%.so$", "")
        if exists(root .. "titan/uv.so") and exists(root .. "titan/timer.so") then
            return template
        end
    end
    error("Phase 2 specs require prebuilt titan/uv.so and titan/timer.so aliases",
        0)
end
M.alias_template = find_alias_template

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

local function copy_file(source, destination)
    local input = assert(io.open(source, "rb"))
    local contents = input:read("*a")
    input:close()
    local output = assert(io.open(destination, "wb"))
    output:write(contents)
    output:close()
end

function M.workspace(label)
    local path = os.tmpname() .. "-titan-phase2-" .. label
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    assert.truthy(lfs.mkdir(path .. "/src"))
    -- A private runtime copy prevents driver mtime checks from rebuilding the
    -- repository's shared titan.o when specs execute concurrently.
    local ok, _, output = run("cp -R " .. quote(REPO .. "/titan-runtime") ..
        " " .. quote(path .. "/titan-runtime"))
    assert.truthy(ok, output)
    return path
end

function M.copy_fixture(workspace, fixture, modname)
    copy_file(REPO .. "/spec/fixtures/uv/phase2/" .. fixture,
        workspace .. "/src/" .. modname .. ".titan")
end

function M.copy_source(workspace, source, modname)
    copy_file(REPO .. "/" .. source,
        workspace .. "/src/" .. modname .. ".titan")
end

function M.compile(workspace, modname, options)
    options = options or {}
    local stdlib = options.stdlib or find_standard_dir()
    local lua = exists(REPO .. "/lua") and
        REPO .. "/lua" or REPO .. "/.lua/bin/lua"
    local environment = {
        "env CCACHE_DISABLE=1",
        "TITAN_STDLIB_PATH=" .. quote(stdlib),
        "TITAN_PATH_0_11=" .. quote(stdlib),
    }
    if options.cppflags then
        environment[#environment + 1] =
            "TITAN_EXTRA_CPPFLAGS=" .. quote(options.cppflags)
    end
    if options.cflags then
        environment[#environment + 1] =
            "TITAN_EXTRA_CFLAGS=" .. quote(options.cflags)
    end
    if options.ldflags then
        environment[#environment + 1] =
            "TITAN_EXTRA_LDFLAGS=" .. quote(options.ldflags)
    end
    local command = {
        table.concat(environment, " "),
        quote(lua), quote(REPO .. "/spec/support/phase2_compile.lua"),
        quote(REPO), quote(workspace .. "/src"), quote(modname),
        quote(workspace .. "/titan-runtime"),
    }
    for _, object in ipairs(options.extra_objects or {}) do
        command[#command + 1] = quote(object)
    end
    local ok, _, output = run(table.concat(command, " "), workspace)
    assert.truthy(ok, output)
end

local function compiler_command()
    local lua = exists(REPO .. "/lua") and
        REPO .. "/lua" or REPO .. "/.lua/bin/lua"
    return quote(lua) .. " -e " .. quote(
        "package.path=\"" .. REPO .. "/?.lua;" .. REPO ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(REPO .. "/titanc")
end

function M.variant_workspace(transformer)
    local workspace = M.workspace("variant")
    assert.truthy(lfs.mkdir(workspace .. "/stdlib"))
    assert.truthy(lfs.mkdir(workspace .. "/titan"))
    local transform = transformer
    if transform:sub(1, 1) ~= "/" then transform = REPO .. "/" .. transform end
    local raw_lua = exists(REPO .. "/.lua/bin/lua") and
        REPO .. "/.lua/bin/lua" or REPO .. "/lua"
    local ok, _, output = run(table.concat({
        quote(raw_lua), quote(transform), quote(REPO .. "/stdlib/uv.titan"),
        quote(workspace .. "/stdlib/uv.titan"),
    }, " "), workspace)
    assert.truthy(ok, output)
    copy_file(REPO .. "/stdlib/timer.titan",
        workspace .. "/stdlib/timer.titan")
    copy_file(REPO .. "/stdlib/coroutine.titan",
        workspace .. "/stdlib/coroutine.titan")
    ok, _, output = run("ln -s " .. quote(REPO .. "/lua-5.5.0") ..
        " " .. quote(workspace .. "/lua-5.5.0"), workspace)
    assert.truthy(ok, output)
    ok, _, output = run("ln -s " .. quote(REPO .. "/libbacktrace") ..
        " " .. quote(workspace .. "/libbacktrace"), workspace)
    assert.truthy(ok, output)

    local base = table.concat({
        "env CCACHE_DISABLE=1", "TITAN_PATH_0_11=", "TITAN_PATH=",
        "TITAN_STDLIB_PATH=" .. quote(workspace),
    }, " ")
    assert.truthy(exists(workspace .. "/titan-runtime/titan_coro.o"),
        "Phase 2 variant requires make stdlib's titan_coro.o")
    local coroutine_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=''", "TITAN_EXTRA_CFLAGS=''",
        "TITAN_EXTRA_LDFLAGS=''", compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.coroutine coroutine -X",
        quote(workspace .. "/titan-runtime/titan_coro.o"),
    }, " ")
    ok, _, output = run(coroutine_command, workspace)
    assert.truthy(ok, output)

    local cppflags, ldflags, archive = host_libuv_config()
    local uv_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=" .. quote(cppflags),
        "TITAN_EXTRA_CFLAGS=" .. quote("-fno-strict-aliasing"),
        "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags), compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.uv uv -X",
        quote(workspace .. "/titan-runtime/titan_uv.o"), quote(archive),
    }, " ")
    ok, _, output = run(uv_command, workspace)
    assert.truthy(ok, output)

    local timer_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=''", "TITAN_EXTRA_CFLAGS=''",
        "TITAN_EXTRA_LDFLAGS=''", compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.timer timer",
    }, " ")
    ok, _, output = run(timer_command, workspace)
    assert.truthy(ok, output)
    ok, _, output = run("ln -s ../coroutine.so titan/coroutine.so", workspace)
    assert.truthy(ok, output)
    ok, _, output = run("ln -s ../uv.so titan/uv.so", workspace)
    assert.truthy(ok, output)
    ok, _, output = run("ln -s ../timer.so titan/timer.so", workspace)
    assert.truthy(ok, output)
    return workspace
end

function M.variant_lua_command(workspace, script, ...)
    local lua = exists(REPO .. "/.lua/bin/lua") and
        REPO .. "/.lua/bin/lua" or REPO .. "/lua"
    local args = { ... }
    for index, value in ipairs(args) do args[index] = quote(value) end
    local cpath = workspace .. "/?.so;" ..
        REPO .. "/lua_modules/lib/lua/5.5/?.so;;"
    return table.concat({
        "env TITAN_STDLIB_PATH=" .. quote(workspace),
        "LUA_CPATH=" .. quote(cpath), quote(lua), quote(script),
        table.concat(args, " "),
    }, " ")
end

function M.variant_app_command(workspace, modname)
    return "env TITAN_STDLIB_PATH=" .. quote(workspace) .. " " ..
        quote(workspace .. "/" .. modname)
end

function M.lua_command(workspace, script, ...)
    local stdlib = find_standard_dir()
    local alias = find_alias_template()
    local lua = exists(REPO .. "/.lua/bin/lua") and
        REPO .. "/.lua/bin/lua" or REPO .. "/lua"
    local args = { ... }
    for index, value in ipairs(args) do args[index] = quote(value) end
    return table.concat({
        "env TITAN_STDLIB_PATH=" .. quote(stdlib),
        "LUA_CPATH=" .. quote(workspace .. "/?.so;" .. alias .. ";;"),
        quote(lua), quote(script), table.concat(args, " "),
    }, " ")
end

function M.app_command(workspace, modname)
    local stdlib = find_standard_dir()
    return "env TITAN_STDLIB_PATH=" .. quote(stdlib) .. " " ..
        quote(workspace .. "/" .. modname)
end

function M.read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

function M.c_function_definition(source, signature, following_signature)
    local cursor = 1
    while true do
        local first = source:find(signature, cursor, true)
        assert.truthy(first, "missing C function definition: " .. signature)
        local brace = source:find("{", first + #signature, true)
        local semicolon = source:find(";", first + #signature, true)
        if brace and (not semicolon or brace < semicolon) then
            local following = source:find(following_signature, brace + 1, true)
            assert.truthy(following,
                "missing C function following " .. signature)
            return source:sub(first, following - 1)
        end
        cursor = first + #signature
    end
end

function M.cleanup(workspace)
    if workspace then run("rm -rf " .. quote(workspace)) end
end

M.repo = REPO
return M

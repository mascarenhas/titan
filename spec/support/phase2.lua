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

-- Building the transformed uv standard module dominates the async coder
-- suites (roughly twenty seconds per invocation). Busted loads every spec in
-- one Lua process, so keep one pristine template for each identical standard
-- library variant and clone it for each caller. Callers still receive private
-- source, runtime, generated-object, and DSO trees; only the compilation work
-- is shared.
-- Busted auto-insulates each spec file by restoring _G and package.loaded.
-- The Lua registry is deliberately outside that snapshot, so independently
-- loaded copies of this helper still share the same process-local templates.
local registry = debug.getregistry()
local cache_registry_key =
    "titan.spec.support.phase2.workspace-templates:" .. REPO
local workspace_templates = registry[cache_registry_key]
if not workspace_templates then
    workspace_templates = setmetatable({}, {
        __gc = function(templates)
            for _, path in pairs(templates) do
                if type(path) == "string" then
                    pcall(run, "rm -rf " .. quote(path))
                end
            end
            registry[cache_registry_key] = nil
        end,
    })
    registry[cache_registry_key] = workspace_templates
end

local function exists(path)
    return lfs.attributes(path) ~= nil
end

local function move_compiled_module(workspace, module)
    local source = workspace .. "/" .. module .. ".so"
    local destination = workspace .. "/titan/" .. module .. ".so"
    assert.truthy(os.rename(source, destination))
    if exists(source .. ".dSYM") then
        assert.truthy(os.rename(source .. ".dSYM", destination .. ".dSYM"))
    end
end
M.move_compiled_module = move_compiled_module

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
M.host_lua = host_lua

local function fresh_workspace_path(label)
    local path = os.tmpname() .. "-titan-phase2-" .. label
    os.remove(path)
    return path
end

local function clone_workspace(template)
    local path = fresh_workspace_path("cached")
    -- -p matters here: driver.compile's private-runtime staleness check must
    -- see the same source/object ordering as the prepared template on both
    -- GNU and BSD/macOS cp.
    local ok, _, output = run("cp -Rp " .. quote(template) ..
        " " .. quote(path))
    assert.truthy(ok, output)
    return path
end

local function cache_context()
    return table.concat({
        os.getenv("CC") or "",
        os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
        os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or "",
    }, "\0")
end

-- Cache only within this Lua process: every fresh Busted/CI invocation still
-- rebuilds variants from the current source, transformer, native objects, and
-- libuv archive. The successfully built workspace becomes the immutable
-- template until Lua closes; callers always receive disposable clones.
function M.cached_workspace(key, builder)
    local full_key = key .. "\0" .. cache_context()
    local template = workspace_templates[full_key]
    if template then
        assert.truthy(exists(template),
            "cached test workspace disappeared: " .. template)
        return clone_workspace(template)
    end

    template = assert(builder())
    workspace_templates[full_key] = template
    return clone_workspace(template)
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
    error("Phase 2 specs require prebuilt coroutine.so, uv.so, and timer.so; " ..
          "run the focused Makefile stdlib target first", 0)
end
M.standard_dir = find_standard_dir

local function canonical_cpath(stdlib)
    local parent = stdlib:match("^(.*)/titan$")
    assert.truthy(parent,
        "canonical standard directory must end in /titan: " .. stdlib)
    return parent .. "/?.so"
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
    local lua = host_lua()
    local environment = {
        "env CCACHE_DISABLE=1",
        "TITAN_STDLIB_PATH=" .. quote(stdlib),
        "TITAN_PATH_0_11=" .. quote(stdlib),
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
    local lua = host_lua()
    return quote(lua) .. " -e " .. quote(
        "package.path=\"" .. REPO .. "/?.lua;" .. REPO ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(REPO .. "/titanc")
end

local function build_variant_workspace(transformer)
    local workspace = M.workspace("variant")
    assert.truthy(lfs.mkdir(workspace .. "/stdlib"))
    assert.truthy(lfs.mkdir(workspace .. "/titan"))
    local transform = transformer
    if transform:sub(1, 1) ~= "/" then transform = REPO .. "/" .. transform end
    local raw_lua = host_lua()
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
        "TITAN_STDLIB_PATH=" .. quote(workspace .. "/titan"),
    }, " ")
    -- Sanitizer CI opts private generated variants in explicitly. Ordinary
    -- focused runs retain the empty flags that keep these workspaces isolated
    -- from a developer's ambient build configuration.
    local variant_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local variant_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    assert.truthy(exists(workspace .. "/titan-runtime/libtitan.a"),
        "Phase 2 variant requires make runtime's libtitan.a")
    local coroutine_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(variant_cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(variant_ldflags), compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.coroutine coroutine",
    }, " ")
    ok, _, output = run(coroutine_command, workspace)
    assert.truthy(ok, output)
    move_compiled_module(workspace, "coroutine")

    local cppflags, ldflags, archive = host_libuv_config()
    ldflags = archive .. " " .. ldflags
    local uv_cflags = variant_cflags
    if #uv_cflags > 0 then uv_cflags = uv_cflags .. " " end
    uv_cflags = uv_cflags .. "-fno-strict-aliasing"
    if #variant_ldflags > 0 then
        ldflags = variant_ldflags .. " " .. ldflags
    end
    local uv_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=" .. quote(cppflags),
        "TITAN_EXTRA_CFLAGS=" .. quote(uv_cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags), compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.uv uv",
    }, " ")
    ok, _, output = run(uv_command, workspace)
    assert.truthy(ok, output)
    move_compiled_module(workspace, "uv")

    local timer_command = table.concat({
        base, "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(variant_cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(variant_ldflags), compiler_command(),
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.timer timer",
    }, " ")
    ok, _, output = run(timer_command, workspace)
    assert.truthy(ok, output)
    move_compiled_module(workspace, "timer")
    return workspace
end

function M.variant_workspace(transformer)
    local transform = transformer
    if transform:sub(1, 1) ~= "/" then transform = REPO .. "/" .. transform end
    return build_variant_workspace(transform)
end

function M.variant_lua_command(workspace, script, ...)
    local lua = host_lua()
    local args = { ... }
    for index, value in ipairs(args) do args[index] = quote(value) end
    local cpath = workspace .. "/?.so;;"
    return table.concat({
        "env TITAN_STDLIB_PATH=" .. quote(workspace .. "/titan"),
        "LUA_CPATH=" .. quote(cpath), quote(lua), quote(script),
        table.concat(args, " "),
    }, " ")
end

function M.variant_app_command(workspace, modname)
    return "env TITAN_STDLIB_PATH=" .. quote(workspace .. "/titan") .. " " ..
        quote(workspace .. "/" .. modname)
end

function M.lua_command(workspace, script, ...)
    local stdlib = find_standard_dir()
    local alias = canonical_cpath(stdlib)
    local lua = host_lua()
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

local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local assert = require "luassert"
local installed_prefix = require "spec.support.installed_prefix"

local M = {}
local REPO = lfs.currentdir()
local STANDARD_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "path", "peg", "string", "math", "lua", "iteration", "gc",
    "test", "reflect", "sqlite3", "json", "protobuf", "transfer",
}


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
    return "lua"
end

local function fresh_workspace_path(label)
    local path = temporary.name("-titan-async-stdlib-" .. label)
    os.remove(path)
    return path
end

local function production_layout(library_root, shim_root)
    return {
        kind = "container",
        library_root = library_root,
        shim_root = shim_root,
        container = library_root .. "/titan.so",
    }
end

local function valid_production_layout(layout)
    if not exists(layout.container) then return false end
    for _, module in ipairs(STANDARD_MODULES) do
        if not exists(layout.shim_root .. "/titan/" .. module .. ".lua") then
            return false
        end
    end
    return true
end

local function find_standard_layout()
    local layouts = {}
    local prefix = os.getenv("PREFIX")
    if prefix and prefix ~= "" then
        layouts[#layouts + 1] = production_layout(
            prefix .. "/lib/titan/0.6", prefix .. "/share/lua/5.5")
    end

    -- Discover the two owners independently. The supported installation puts
    -- both under one rocks tree today, but PREFIX/ROCKS_TREE equality is
    -- deployment policy rather than a helper invariant.
    local installed_container = package.searchpath("titan", package.cpath)
    local installed_shim = package.searchpath(
        "titan.coroutine", package.path)
    local installed_root = installed_container and
        installed_container:match(
            "^(.*)/lib/titan/0%.6/titan%.so$")
    local installed_shim_root = installed_shim and
        installed_shim:match("^(.*)/titan/coroutine%.lua$")
    if installed_root and installed_shim_root then
        layouts[#layouts + 1] = production_layout(
            installed_root .. "/lib/titan/0.6", installed_shim_root)
    end

    layouts[#layouts + 1] = production_layout(REPO .. "/out", REPO .. "/out")
    for _, layout in ipairs(layouts) do
        if valid_production_layout(layout) then return layout end
    end
    error("async stdlib specs require the combined titan.so and all twenty-five " ..
          "generated titan/*.lua shims; run make stdlib first", 0)

end
M.standard_layout = find_standard_layout

local function exact_layout(root)
    assert.truthy(type(root) == "string" and root ~= "",
        "exact standard-library root must be a nonempty path")
    assert.falsy(exists(root .. "/titan.so"),
        "exact standard-library variant must not contain shallow titan.so: " ..
            root)
    return {
        kind = "exact",
        library_root = root,
        shim_root = root,
        providers = {},
    }
end
M.exact_layout = exact_layout

local function assert_layout(layout)
    assert.truthy(type(layout) == "table", "stdlib layout must be a table")
    assert.truthy(layout.kind == "container" or layout.kind == "exact",
        "unknown stdlib layout kind: " .. tostring(layout.kind))
    assert.truthy(type(layout.library_root) == "string",
        "stdlib layout is missing library_root")
    assert.truthy(type(layout.shim_root) == "string",
        "stdlib layout is missing shim_root")
    if layout.kind == "container" then
        assert.equals(layout.library_root .. "/titan.so", layout.container)
    elseif layout.container then
        assert.equals(layout.library_root .. "/titan.so", layout.container)
        assert.truthy(exists(layout.container),
            "exact standard-library variant is missing its grouped provider")
    else
        assert.falsy(exists(layout.library_root .. "/titan.so"),
            "exact standard-library variant has an unregistered titan.so")
    end
    return layout
end

local function register_exact_provider(layout, modname)
    assert.equals("exact", assert_layout(layout).kind)
    local relative = modname:gsub("%.", "/")
    local provider = layout.library_root .. "/" .. relative .. ".so"
    local shim = layout.shim_root .. "/" .. relative .. ".lua"
    assert.truthy(exists(provider),
        "exact variant is missing provider " .. provider)
    assert.truthy(exists(shim), "exact variant is missing shim " .. shim)
    local contents = M.read(shim)
    assert.truthy(contents:find(
        "package.searchpath(" .. string.format("%q", modname) ..
            ", package.cpath)", 1, true),
        "exact variant shim does not select provider " .. modname)
    layout.providers[modname] = { provider = provider, shim = shim }
end
M.register_exact_provider = register_exact_provider

local function canonical_cpath(layout)
    return assert_layout(layout).library_root .. "/?.so"
end
M.canonical_cpath = canonical_cpath

local function canonical_lua_path(layout)
    return assert_layout(layout).shim_root .. "/?.lua"
end
M.canonical_lua_path = canonical_lua_path

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
    -- Source-variant compilers own one matching Lua source tree and archive.
    -- Populate it from the installed SDK rather than checkout build outputs.
    local prefix = installed_prefix.active()
    local lua_source = path .. "/lua-5.5.1"
    ok, _, output = run("cp -Rp " .. quote(prefix .. "/src/lua-5.5.1") ..
        " " .. quote(lua_source))
    assert.truthy(ok, output)
    ok, _, output = run("cp -p " .. quote(prefix .. "/lib/liblua.a") ..
        " " .. quote(lua_source .. "/liblua.a"))
    assert.truthy(ok, output)
    return path
end

-- Build the command that refreshes only the copied runtime in an isolated
-- spec workspace. The shared dependency archives are prepared before these
-- tests and remain read-only: independent Busted workers must not re-enter
-- their FORCE-backed configuration recipes.
function M.private_runtime_make_command(workspace, dry_run)
    assert.truthy(type(workspace) == "string" and workspace ~= "",
        "private runtime workspace must be a nonempty path")
    assert.equals("boolean", type(dry_run),
        "private runtime dry-run policy must be boolean")
    assert.truthy(exists(workspace .. "/titan-runtime"),
        "private runtime workspace is missing titan-runtime")
    local input = assert(io.open(REPO .. "/Makefile", "rb"))
    local makefile = assert(input:read("*a"))
    assert.truthy(input:close())
    local version = assert(makefile:match(
        "LIBUV_VERSION%s*:=%s*([%w%.%-]+)"))
    local libbacktrace_archive =
        REPO .. "/libbacktrace/.libs/libbacktrace.a"
    local libuv_archive = REPO .. "/libuv-build/libuv.a"
    local prefix = installed_prefix.active()
    assert.truthy(exists(libbacktrace_archive),
        "run make libbacktrace first")
    assert.truthy(exists(libuv_archive), "run make libuv first")
    local command = table.concat({
        "env CCACHE_DISABLE=1 make --no-print-directory -f",
        quote(REPO .. "/Makefile"),
        dry_run and "--dry-run" or "",
        "--old-file=" .. quote(libbacktrace_archive),
        "--old-file=" .. quote(libuv_archive),
        "PREFIX=" .. quote(prefix),
        "TITAN_RUNTIME_LUA_SOURCE_PATH=" ..
            quote(workspace .. "/lua-5.5.1"),
        "TITAN_RUNTIME_LUA_LIB=" ..
            quote(workspace .. "/lua-5.5.1/liblua.a"),
        "LIBBT_DIR=" .. quote(REPO .. "/libbacktrace"),
        "LIBUV_SRC_DIR=" .. quote(REPO .. "/libuv-v" .. version),
        "LIBUV_BUILD_DIR=" .. quote(REPO .. "/libuv-build"),
        "titan-runtime/libtitan.a",
    }, " ")
    return command
end

-- Refresh only the copied runtime in an isolated spec workspace. This keeps
-- focused source-variant builds independent while preserving all shared
-- Make-owned dependency state.
function M.refresh_private_runtime(workspace)
    local command = M.private_runtime_make_command(workspace, false)
    local ok, _, output = run(command, workspace)
    assert.truthy(ok, output)
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
    local layout = assert_layout(options.layout or find_standard_layout())
    local lua = host_lua()
    local environment = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5 -u TITAN_ROCKS_ROOT CCACHE_DISABLE=1",
        "TITAN_PATH_0_6=" .. quote(layout.library_root),
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
        quote(workspace .. "/lua-5.5.1"),
    }
    for _, object in ipairs(options.extra_objects or {}) do
        command[#command + 1] = quote(object)
    end
    local ok, _, output = run(table.concat(command, " "), workspace)
    assert.truthy(ok, output)
end

-- Compile source roots that use uv's source-private bridge in one ordinary
-- multi-root invocation. This deliberately delegates provider planning,
-- static-input finalization, validation, and publication to titanc rather than
-- recreating that policy in the spec helper.
function M.compile_bundle(workspace, roots, options)
    options = options or {}
    local layout = assert_layout(assert(options.layout))
    assert.equals("exact", layout.kind)
    assert.falsy(layout.container,
        "an exact workspace may publish only one grouped provider")
    assert.truthy(type(roots) == "table" and #roots > 1,
        "a grouped source build requires multiple roots")

    local environment = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5 -u TITAN_ROCKS_ROOT CCACHE_DISABLE=1",
        "TITAN_PATH_0_6=" .. quote(layout.library_root),
        "TITAN_PATH=",
    }
    if options.cppflags and #options.cppflags > 0 then
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
        quote(host_lua()),
        quote(REPO .. "/spec/support/async_stdlib_bundle_compile.lua"),
        quote(REPO), quote(workspace .. "/src"),
        quote(workspace .. "/titan-runtime"),
        "--tree", quote(workspace .. "/src"),
        "--lua", quote(workspace .. "/lua-5.5.1"),
    }
    for _, root in ipairs(roots) do command[#command + 1] = quote(root) end
    local extra_objects = options.extra_objects or {}
    if #extra_objects > 0 then
        command[#command + 1] = "-X"
        for _, object in ipairs(extra_objects) do
            command[#command + 1] = quote(object)
        end
    end
    local ok, _, output = run(table.concat(command, " "), workspace)
    assert.truthy(ok, output)
    layout.container = layout.library_root .. "/titan.so"
    assert_layout(layout)
end

-- Build uv and every explicit source consumer needed by a fixture in one
-- canonical prefix provider. Each facade's `uv.titan` edge requires uv source
-- even if a compiled provider already exists; passing all roots together also
-- keeps the fixture in one canonical provider rather than separate outputs.
function M.prepare_async_core(workspace, layout, facades)
    facades = facades or {}
    local allowed = { timer = true, fs = true, net = true, os = true }
    local roots = { "titan.coroutine", "titan.uv", "titan.async" }
    local bundled = {
        ["titan.coroutine"] = true,
        ["titan.uv"] = true,
        ["titan.async"] = true,
    }

    M.write_source(workspace, "titan.coroutine",
        M.read("titan/coroutine.titan"))
    for _, name in ipairs({
        "uv", "runtime", "task", "file", "tcp", "process", "os",
    }) do
        M.write_source(workspace, "titan.uv." .. name,
            M.read("titan/uv/" .. name .. ".titan"))
    end
    M.write_source(workspace, "titan.async",
        M.read("titan/async.titan"))

    for _, name in ipairs(facades) do
        assert.truthy(allowed[name],
            "unsupported direct uv facade in exact bundle: " ..
                tostring(name))
        local modname = "titan." .. name
        assert.falsy(bundled[modname],
            "duplicate direct uv facade in exact bundle: " .. name)
        bundled[modname] = true
        roots[#roots + 1] = modname
        M.write_source(workspace, modname,
            M.read("titan/" .. name .. ".titan"))
    end

    local cppflags, ldflags, archive = host_libuv_config()
    local support = workspace .. "/titan-runtime/ltitanlib.o"
    assert.truthy(exists(support),
        "exact grouped stdlib build requires prepared ltitanlib.o")
    M.compile_bundle(workspace, roots, {
        layout = layout,
        cppflags = cppflags,
        cflags = "-fno-strict-aliasing",
        ldflags = ldflags,
        extra_objects = { support, archive },
    })

    for _, modname in ipairs(roots) do
        local relative = modname:gsub("%.", "/")
        local shim = layout.shim_root .. "/" .. relative .. ".lua"
        assert.truthy(exists(shim),
            "grouped stdlib provider is missing shim " .. shim)
        local contents = M.read(shim)
        assert.truthy(contents:find(
            'package.searchpath("titan", package.cpath)', 1, true),
            "grouped stdlib shim does not select prefix provider titan")
        layout.providers[modname] = {
            provider = layout.container,
            shim = shim,
        }
    end
end

-- Build the exact GC facade used by standard modules that configure weak
-- typed Maps without duplicating raw Lua-metatable operations.
function M.prepare_gc(workspace, layout)
    M.write_source(workspace, "titan.gc", M.read("titan/gc.titan"))
    M.compile(workspace, "titan.gc", {
        layout = layout,
        cppflags = "",
    })
    register_exact_provider(layout, "titan.gc")
end

function M.run_lua_source(workspace, source, options)
    options = options or {}
    local layout = assert_layout(options.layout or find_standard_layout())
    local cpath = workspace .. "/?.so;" .. canonical_cpath(layout)
    if not layout.container then
        local support_layout = find_standard_layout()
        if support_layout.library_root ~= layout.library_root then
            cpath = cpath .. ";" .. canonical_cpath(support_layout)
        end
    end
    cpath = cpath .. ";;"
    local lua_path = workspace .. "/?.lua;" ..
        canonical_lua_path(layout) .. ";" .. REPO .. "/?.lua;" ..
        REPO .. "/?/init.lua;;"
    local lua = host_lua()
    local command = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
        "TITAN_PATH_0_6=" .. quote(layout.library_root),
        "TITAN_PATH=",
        "LUA_PATH=" .. quote(lua_path),
        "LUA_PATH_5_5=" .. quote(lua_path),
        "LUA_CPATH=" .. quote(cpath),
        "LUA_CPATH_5_5=" .. quote(cpath),
    }
    for _, argument in ipairs(options.exec_prefix or {}) do
        command[#command + 1] = quote(argument)
    end
    command[#command + 1] = quote(lua)
    command[#command + 1] = "-e"
    command[#command + 1] = quote(source)
    return run(table.concat(command, " "), options.cwd or workspace)
end

local function app_command(workspace, modname)
    local layout = find_standard_layout()
    local module_path = modname:gsub("%.", "/")
    local basename = modname:match("([^.]+)$")
    local source_main = workspace .. "/src/" .. module_path .. "/" ..
        basename .. ".titan"
    local program_output = module_path
    if lfs.attributes(source_main, "mode") == "file" then
        program_output = program_output .. "__main"
    end
    return "env -u LUA_PATH -u LUA_CPATH" ..
        " -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
        " TITAN_PATH_0_6=" .. quote(layout.library_root) .. " " ..
        "TITAN_PATH= " .. quote(workspace .. "/" .. program_output)
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

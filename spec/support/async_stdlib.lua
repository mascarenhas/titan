local lfs = require "lfs"
local assert = require "luassert"

local M = {}
local REPO = lfs.currentdir()
local STANDARD_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "os",
    "peg", "string", "math", "lua", "iter", "gc",
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
    local path = os.tmpname() .. "-titan-async-stdlib-" .. label
    os.remove(path)
    return path
end

local function production_layout(abi_root, shim_root)
    return {
        kind = "container",
        abi_root = abi_root,
        shim_root = shim_root,
        container = abi_root .. "/titan.so",
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
            prefix .. "/lib/titan/0.20", prefix .. "/share/lua/5.5")
    end

    -- Discover the two owners independently. The supported installation puts
    -- both under one rocks tree today, but PREFIX/ROCKS_TREE equality is
    -- deployment policy rather than a helper invariant.
    local installed_container = package.searchpath("titan", package.cpath)
    local installed_shim = package.searchpath(
        "titan.coroutine", package.path)
    local installed_abi_root = installed_container and
        installed_container:match("^(.*)/lib/titan/0%.20/titan%.so$")
    local installed_shim_root = installed_shim and
        installed_shim:match("^(.*)/titan/coroutine%.lua$")
    if installed_abi_root and installed_shim_root then
        layouts[#layouts + 1] = production_layout(
            installed_abi_root .. "/lib/titan/0.20", installed_shim_root)
    end

    layouts[#layouts + 1] = production_layout(REPO, REPO)
    for _, layout in ipairs(layouts) do
        if valid_production_layout(layout) then return layout end
    end
    error("async stdlib specs require the combined titan.so and all fourteen " ..
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
        abi_root = root,
        shim_root = root,
        providers = {},
    }
end
M.exact_layout = exact_layout

local function assert_layout(layout)
    assert.truthy(type(layout) == "table", "stdlib layout must be a table")
    assert.truthy(layout.kind == "container" or layout.kind == "exact",
        "unknown stdlib layout kind: " .. tostring(layout.kind))
    assert.truthy(type(layout.abi_root) == "string",
        "stdlib layout is missing abi_root")
    assert.truthy(type(layout.shim_root) == "string",
        "stdlib layout is missing shim_root")
    if layout.kind == "container" then
        assert.equals(layout.abi_root .. "/titan.so", layout.container)
    else
        assert.falsy(exists(layout.abi_root .. "/titan.so"),
            "exact standard-library variant must not contain shallow titan.so")
    end
    return layout
end

local function register_exact_provider(layout, modname)
    assert.equals("exact", assert_layout(layout).kind)
    local relative = modname:gsub("%.", "/")
    local provider = layout.abi_root .. "/" .. relative .. ".so"
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
    return assert_layout(layout).abi_root .. "/?.so"
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

-- Refresh only the copied runtime in an isolated spec workspace. This keeps
-- focused source-variant builds independent of a concurrently stale or
-- rebuilding checkout archive while preserving the shared Make-owned state.
function M.refresh_private_runtime(workspace)
    assert.truthy(type(workspace) == "string" and workspace ~= "",
        "private runtime workspace must be a nonempty path")
    assert.truthy(exists(workspace .. "/titan-runtime"),
        "private runtime workspace is missing titan-runtime")
    local input = assert(io.open(REPO .. "/Makefile", "rb"))
    local makefile = assert(input:read("*a"))
    assert.truthy(input:close())
    local version = assert(makefile:match(
        "LIBUV_VERSION%s*:=%s*([%w%.%-]+)"))
    local command = table.concat({
        "env CCACHE_DISABLE=1 make --no-print-directory -f",
        quote(REPO .. "/Makefile"),
        "TITAN_RUNTIME_LUA_SOURCE_PATH=" ..
            quote(REPO .. "/lua-5.5.0/src"),
        "LIBBT_DIR=" .. quote(REPO .. "/libbacktrace"),
        "LIBUV_SRC_DIR=" .. quote(REPO .. "/libuv-v" .. version),
        "LIBUV_BUILD_DIR=" .. quote(REPO .. "/libuv-build"),
        "titan-runtime/libtitan.a",
    }, " ")
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
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5 CCACHE_DISABLE=1",
        "TITAN_PATH_0_20=" .. quote(layout.abi_root),
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

-- Build the exact coroutine/uv/async dependency chain needed by source
-- variants that now yield through the public async facade. Keeping this in
-- one helper prevents PEG/string specs from silently falling back to the
-- checkout's combined provider while TITAN_PATH_0_20 names a private root.
function M.prepare_async_core(workspace, layout)
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

    M.compile(workspace, "titan.coroutine", {
        layout = layout,
        cppflags = "",
    })
    register_exact_provider(layout, "titan.coroutine")

    local cppflags, ldflags, archive = host_libuv_config()
    M.compile(workspace, "titan.uv", {
        layout = layout,
        cppflags = cppflags,
        cflags = "-fno-strict-aliasing",
        ldflags = archive .. " " .. ldflags,
    })
    register_exact_provider(layout, "titan.uv")

    M.compile(workspace, "titan.async", {
        layout = layout,
        cppflags = "",
    })
    register_exact_provider(layout, "titan.async")
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

local function build_variant_workspace(transformer, options)
    options = options or {}
    assert.truthy(type(options) == "table",
        "async stdlib variant options must be a table")
    assert.truthy(options.facades == nil or type(options.facades) == "boolean",
        "async stdlib variant facades option must be boolean")
    local build_facades = options.facades ~= false
    local workspace = M.workspace("variant")
    local built, variant_or_error = pcall(function()
    M.refresh_private_runtime(workspace)
    assert.truthy(lfs.mkdir(workspace .. "/titan"))
    make_directory(workspace .. "/src/titan")
    local transformers
    if type(transformer) == "string" then
        transformers = { transformer }
    else
        assert.truthy(type(transformer) == "table",
            "async stdlib variant transformer must be a path or ordered array")
        assert.truthy(#transformer > 0,
            "async stdlib variant transformer array must not be empty")
        transformers = transformer
        for key in pairs(transformers) do
            assert.truthy(type(key) == "number" and key >= 1
                and key <= #transformers and key % 1 == 0,
                "async stdlib variant transformers must be a dense array")
        end
    end

    local raw_lua = host_lua()
    local input = REPO .. "/titan/uv"
    for index, configured in ipairs(transformers) do
        assert.truthy(type(configured) == "string" and configured ~= "",
            "async stdlib variant transformer paths must be nonempty strings")
        local transform = configured
        if transform:sub(1, 1) ~= "/" then
            transform = REPO .. "/" .. transform
        end
        local destination = index == #transformers
            and workspace .. "/src/titan/uv"
            or workspace .. "/variant-stage-" .. tostring(index)
        local ok, _, output = run(table.concat({
            quote(raw_lua), quote(transform), quote(input),
            quote(destination),
        }, " "), workspace)
        assert.truthy(ok, output)
        input = destination
    end
    assert.truthy(exists(workspace .. "/src/titan/uv/uv.titan"),
        "async stdlib variant transformer did not copy the folder main")
    copy_file(REPO .. "/titan/timer.titan",
        workspace .. "/src/titan/timer.titan")
    copy_file(REPO .. "/titan/async.titan",
        workspace .. "/src/titan/async.titan")
    copy_file(REPO .. "/titan/coroutine.titan",
        workspace .. "/src/titan/coroutine.titan")

    assert.truthy(exists(workspace .. "/titan-runtime/libtitan.a"),
        "async stdlib variant requires make runtime's libtitan.a")
    local variant_layout = exact_layout(workspace)
    M.compile(workspace, "titan.coroutine", {
        layout = variant_layout,
        cppflags = "",
    })
    register_exact_provider(variant_layout, "titan.coroutine")

    local cppflags, ldflags, archive = host_libuv_config()
    ldflags = archive .. " " .. ldflags
    M.compile(workspace, "titan.uv", {
        layout = variant_layout,
        cppflags = cppflags,
        cflags = "-fno-strict-aliasing",
        ldflags = ldflags,
    })
    register_exact_provider(variant_layout, "titan.uv")
    if build_facades then
        -- Build the public facades against this private uv image. Its imported
        -- uv module is loaded globally by the ordinary generated dependency
        -- loader, so alias-owned Task methods resolve transitively without
        -- another import in each consumer.
        M.compile(workspace, "titan.async", {
            layout = variant_layout,
            cppflags = "",
        })
        register_exact_provider(variant_layout, "titan.async")
        M.compile(workspace, "titan.timer", {
            layout = variant_layout,
            cppflags = "",
        })
        register_exact_provider(variant_layout, "titan.timer")
    end
    return variant_layout
    end)
    if not built then
        run("rm -rf " .. quote(workspace))
        error(variant_or_error, 0)
    end
    return workspace, variant_or_error
end

function M.variant_workspace(transformer, options)
    return build_variant_workspace(transformer, options)
end

function M.run_lua_source(workspace, source, options)
    options = options or {}
    local layout = assert_layout(options.layout or find_standard_layout())
    local support_layout = find_standard_layout()
    local cpath = workspace .. "/?.so;" .. canonical_cpath(layout)
    if support_layout.abi_root ~= layout.abi_root then
        cpath = cpath .. ";" .. canonical_cpath(support_layout)
    end
    cpath = cpath .. ";;"
    local lua_path = workspace .. "/?.lua;" ..
        canonical_lua_path(layout) .. ";" .. REPO .. "/?.lua;" ..
        REPO .. "/?/init.lua;;"
    local lua = host_lua()
    local command = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
        "TITAN_PATH_0_20=" .. quote(layout.abi_root),
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
        " TITAN_PATH_0_20=" .. quote(layout.abi_root) .. " " ..
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

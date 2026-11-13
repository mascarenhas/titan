-- Browser SDK staging and publication helper for `make browser-sdk`.
local action = ...
assert(type(action) == "string", "usage: browser_sdk.lua <prepare|stage-runtime|finalize> ...")

local function getenv(name)
    local value = os.getenv(name)
    if value == nil or value == "" then return nil end
    return value
end

local prefix = assert(getenv("PREFIX"), "PREFIX is required")
local install_tree = assert(getenv("TITAN_INSTALL_TREE") or prefix, "TITAN_INSTALL_TREE is required")

-- Configure search paths before requiring non-core modules (including lfs),
-- keeping TITAN_INSTALL_TREE ahead of PREFIX to match Makefile's titanc selection.
do
    local roots = install_tree ~= prefix and { install_tree, prefix } or { install_tree }
    local lua_paths, c_paths = {}, {}
    for _, root in ipairs(roots) do
        lua_paths[#lua_paths + 1] = root .. "/share/lua/5.5/?.lua"
        lua_paths[#lua_paths + 1] = root .. "/share/lua/5.5/?/init.lua"
        c_paths[#c_paths + 1] = root .. "/lib/lua/5.5/?.so"
    end
    lua_paths[#lua_paths + 1] = package.path
    c_paths[#c_paths + 1] = package.cpath
    package.path = table.concat(lua_paths, ";")
    package.cpath = table.concat(c_paths, ";")
end

local ok_lfs, lfs = pcall(require, "lfs")
if not ok_lfs or type(lfs) ~= "table" then
    io.stderr:write("browser-sdk: LuaFileSystem (lfs) is unavailable; run 'luarocks make' first\n")
    os.exit(1)
end
local ok_support, support = pcall(require, "titan")
if not ok_support or type(support) ~= "table" then
    io.stderr:write("browser-sdk: installed Titan support module is unavailable; run 'luarocks make' or 'make install-compiler-sdk' first\n")
    os.exit(1)
end

local driver = require "titan-compiler.driver"
local browserlink = require "titan-compiler.browserlink"
local incremental = require "titan-compiler.incremental"
local staticmetadata = require "titan-compiler.staticmetadata"
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local util = require "titan-compiler.util"
local stdlib_checks = dofile("scripts/browser_stdlib.lua")

local strategy = compiler_io.new_sync()

local function fail(message)
    io.stderr:write("browser-sdk: ", tostring(message), "\n")
    os.exit(1)
end

local function ensure_dir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= dir then
        ensure_dir(parent)
    end
    local ok, err = lfs.mkdir(dir)
    if not ok and lfs.attributes(dir, "mode") ~= "directory" then
        fail("cannot create directory '" .. dir .. "': " .. tostring(err))
    end
    return true
end

local function copy_file_atomic(source, destination, executable)
    local bytes, read_err = strategy:read_file(source)
    if not bytes then
        fail("cannot read '" .. source .. "': " .. tostring(read_err))
    end
    ensure_dir(assert(paths.dirname(destination)))
    local written, write_err = strategy:write_file(destination, bytes)
    if not written then
        fail("cannot write '" .. destination .. "': " .. tostring(write_err))
    end
    local mode = executable and "0755" or "0644"
    local chmod_res = strategy:run({ "chmod", mode, destination }, { stderr_to_stdout = true })
    if not chmod_res or not chmod_res.ok then
        fail("cannot chmod '" .. destination .. "'")
    end
end

local function check_no_forbidden_symbols(archive_path, archive)
    local function forbidden(name)
        return name == "dlopen" or name == "dlsym" or name == "dlerror" or
            (type(name) == "string" and (name:match("^backtrace_") or name:match("^__backtrace_")))
    end
    for _, member in ipairs(archive.members or {}) do
        local object = member.object
        for _, import in ipairs(object and object.imports or {}) do
            if import.module == "GOT.mem" or import.module == "GOT.func" then
                fail(string.format("%s(%s): browser archive contains PIC import %s.%s",
                    archive_path, tostring(member.display_name or member.origin),
                    tostring(import.module), tostring(import.name)))
            end
            if forbidden(import.name) then
                fail(string.format("%s(%s): browser archive imports forbidden symbol %q",
                    archive_path, tostring(member.display_name or member.origin), import.name))
            end
        end
        for _, symbol in ipairs(object and object.symbols or {}) do
            if not symbol.defined and forbidden(symbol.name) then
                fail(string.format("%s(%s): browser archive references forbidden symbol %q",
                    archive_path, tostring(member.display_name or member.origin), symbol.name))
            end
        end
    end
end

local function stage_differing_roots()
    local common_headers = {
        "include/minicoro.h",
        "include/titan.h",
        "include/transfer.h",
        "include/titan/ffi.h",
        "include/titan/browser.h",
    }

    local norm_prefix = strategy:realpath(prefix) or paths.normalize(prefix)
    local existing_tree = lfs.attributes(install_tree, "mode") == "directory"
    local norm_tree = (existing_tree and strategy:realpath(install_tree)) or paths.normalize(install_tree)

    if norm_prefix ~= norm_tree then
        -- Validate the authoritative PREFIX browser-Lua prerequisites before
        -- touching or reading the destination tree, so an incomplete PREFIX
        -- fails naming PREFIX rather than consuming a stale ROCKS_TREE copy.
        local runtime_inc = lfs.attributes(install_tree .. "/include/titan.h", "mode") == "file"
            and (install_tree .. "/include") or (prefix .. "/include")
        local prefix_paths = driver.installed_paths(prefix, "browser")
        local prefix_ctx = { io = strategy, extra_ffi_include_dirs = {} }
        local prefix_desc, prefix_err = driver._browser_target.build(prefix_ctx, {
            paths = prefix_paths,
            runtime_include = runtime_inc,
            compile_flags = {},
            build_profile = getenv("TITAN_BUILD_PROFILE") or "production",
        })
        if not prefix_desc then
            fail(prefix_err)
        end

        ensure_dir(install_tree)
        local src_browser = prefix .. "/lib/browser"
        local dst_browser = install_tree .. "/lib/browser"
        local src_inc = src_browser .. "/include"
        ensure_dir(dst_browser .. "/include")
        local existing = strategy:list(dst_browser .. "/include") or {}
        for _, name in ipairs(existing) do
            if name:match("^[^/\\]+[.]h$") then
                strategy:unlink(dst_browser .. "/include/" .. name)
            end
        end
        local headers, list_err = strategy:list(src_inc)
        if not headers then fail(list_err) end
        table.sort(headers, util.bytewise_less)
        for _, name in ipairs(headers) do
            if name:match("^[^/\\]+[.]h$") then
                copy_file_atomic(src_inc .. "/" .. name, dst_browser .. "/include/" .. name, false)
            end
        end
        copy_file_atomic(src_browser .. "/liblua.a", dst_browser .. "/liblua.a", false)
        copy_file_atomic(src_browser .. "/liblua-config.txt", dst_browser .. "/liblua-config.txt", false)

        -- Ensure common Titan headers exist in the differing install tree without
        -- ever touching native Lua headers.
        for _, rel in ipairs(common_headers) do
            local dst = install_tree .. "/" .. rel
            local src = prefix .. "/" .. rel
            if lfs.attributes(dst, "mode") ~= "file" and lfs.attributes(src, "mode") == "file" then
                copy_file_atomic(src, dst, false)
            end
        end
    else
        ensure_dir(install_tree)
    end

    for _, rel in ipairs(common_headers) do
        local hdr = install_tree .. "/" .. rel
        if lfs.attributes(hdr, "mode") ~= "file" then
            fail("missing installed header '" .. hdr .. "'; run 'luarocks make' or 'make install-compiler-sdk' first")
        end
    end
end

local function new_browser_context(output_root)
    driver.TITAN_ROOT = install_tree
    driver.INSTALL_PATHS = driver.installed_paths(install_tree)
    local context = driver.new_resolver_context({
        io = strategy,
        target = "browser",
        output_root = output_root,
    })
    local descriptor, err = driver.context_target_descriptor(context)
    if not descriptor then
        fail(err)
    end
    return context, descriptor, browserlink.sdk_assets(descriptor.paths)
end

local function archive_certified_objects(context, descriptor, output_archive, member_names, object_paths)
    if #object_paths ~= #member_names then
        fail(string.format("expected %d certified objects for '%s', got %d",
            #member_names, output_archive, #object_paths))
    end
    local inputs = {}
    for index, member_name in ipairs(member_names) do
        local object_path = object_paths[index]
        local bytes, read_err = strategy:read_file(object_path)
        if not bytes then
            fail("cannot read certified object '" .. tostring(object_path) .. "': " .. tostring(read_err))
        end
        local classified, classify_err = staticmetadata.classify_object(
            bytes, object_path, descriptor.fingerprint)
        if not classified then
            fail(tostring(classify_err))
        end
        inputs[index] = {
            path = member_name,
            object = classified,
        }
    end
    ensure_dir(assert(paths.dirname(output_archive)))
    local built, build_err = driver.build_static_archive(
        output_archive, inputs, nil, descriptor.fingerprint,
        getenv("TITAN_VERBOSE") == "1", nil, context)
    if not built then
        fail(build_err)
    end
    check_no_forbidden_symbols(output_archive, built.archive)
    return built
end

if action == "prepare" then
    local build_dir = assert(select(2, ...), "build_dir is required")
    local repo_root = select(3, ...)
    stage_differing_roots()
    ensure_dir(build_dir)
    local context, descriptor, assets = new_browser_context(build_dir)
    if repo_root and repo_root ~= "" then
        local node_ok, node_err = driver.browser_node_ready(context, {
            runner = repo_root .. "/titan-runtime/browser/titan-browser-run",
        })
        if not node_ok then
            fail(node_err)
        end
    end
    if lfs.symlinkattributes(assets.sdk_digests) then
        strategy:unlink(assets.sdk_digests)
    end
    ensure_dir(descriptor.paths.titan_bin)
    assert(driver.close_resolver_context(context))
elseif action == "stage-runtime" then
    local build_dir = assert(select(2, ...), "build_dir is required")
    local repo_root = assert(select(3, ...), "repo_root is required")
    local runtime_members = { "titan.o", "minicoro.o", "titan_path.o", "ltitanlib.o" }
    local lpeg_members = { "lplcap.o", "lplcode.o", "lplprint.o", "lpltree.o", "lplvm.o" }
    local total_expected = #runtime_members + #lpeg_members
    local all_paths = {}
    for i = 4, select("#", ...) do
        all_paths[#all_paths + 1] = select(i, ...)
    end
    if #all_paths ~= total_expected then
        fail(string.format("expected %d certified C objects, got %d", total_expected, #all_paths))
    end
    local runtime_paths, lpeg_paths = {}, {}
    for i = 1, #runtime_members do runtime_paths[i] = all_paths[i] end
    for i = 1, #lpeg_members do lpeg_paths[i] = all_paths[#runtime_members + i] end
    local context, descriptor, assets = new_browser_context(build_dir)
    archive_certified_objects(context, descriptor, assets.runtime, runtime_members, runtime_paths)
    archive_certified_objects(context, descriptor, assets.lpeglabel, lpeg_members, lpeg_paths)
    if getenv("TITAN_VERBOSE") == "1" then
        io.stderr:write("browser-sdk: LPegLabel descriptor object flags: ",
            table.concat(descriptor.compile_flags, " "), "\n")
    end

    local browser_src = repo_root .. "/titan-runtime/browser"
    copy_file_atomic(browser_src .. "/titan-browser-library.js", assets.js_library, false)
    copy_file_atomic(browser_src .. "/titan-browser-bridge.js", assets.bridge_library, false)
    copy_file_atomic(browser_src .. "/titan-browser-trace.js", assets.trace_library, false)
    copy_file_atomic(browser_src .. "/titan-browser.mjs", assets.loader, false)
    copy_file_atomic(browser_src .. "/titan-browser-run", assets.runner, true)
    copy_file_atomic(browser_src .. "/titan-browser-run.mjs", assets.runner_module, false)
    copy_file_atomic(browser_src .. "/titan-browser-node-worker.mjs", assets.node_worker, false)
    copy_file_atomic(browser_src .. "/titan-browser-page.mjs", assets.page, false)

    local rocks_tree = getenv("ROCKS_TREE")
    local ready, ready_err = browserlink.require_sdk(context, descriptor, {
        prefix = prefix,
        rocks_tree = rocks_tree,
    })
    if not ready then
        fail(ready_err)
    end
    local node_ok, node_err = driver.browser_node_ready(context, assets)
    if not node_ok then
        fail(node_err)
    end
    assert(driver.close_resolver_context(context))
elseif action == "finalize" then
    local build_dir = assert(select(2, ...), "build_dir is required")
    local staged_provider = build_dir .. "/titan.a"
    local context, descriptor, assets = new_browser_context(build_dir)

    if lfs.attributes(staged_provider, "mode") ~= "file" then
        fail("missing built browser stdlib provider '" .. staged_provider .. "'")
    end
    local scanned, scan_err = staticmetadata.scan_archive(staged_provider, {
        expected_abi = driver.TITAN_ABI_VERSION,
        target = descriptor.fingerprint,
    })
    if not scanned then
        fail(scan_err)
    end
    local valid_provider, provider_err = driver.validate_browser_provider(scanned)
    if not valid_provider then
        fail(provider_err)
    end
    check_no_forbidden_symbols(staged_provider, scanned)
    local closed, closure_err = stdlib_checks.check_archive(staged_provider, scanned)
    if not closed then fail(closure_err) end
    closed, closure_err = stdlib_checks.check_archive(assets.lpeglabel)
    if not closed then fail(closure_err) end
    closed, closure_err = stdlib_checks.check_output(strategy, build_dir)
    if not closed then fail(closure_err) end
    io.stderr:write("browser-sdk: core stdlib closure passed (archive symbols and certified headers)\n")
    local expected_modules = {
        "titan.async", "titan.browser", "titan.coroutine", "titan.gc", "titan.io", "titan.iteration",
        "titan.json", "titan.math", "titan.os", "titan.path", "titan.peg", "titan.protobuf",
        "titan.reflect", "titan.string", "titan.test", "titan.timer", "titan.transfer", "titan.url",
    }
    if #(scanned.key_order or {}) ~= #expected_modules then
        fail("browser provider titan.a has unexpected module count: " .. tostring(#(scanned.key_order or {})))
    end
    for index, modname in ipairs(expected_modules) do
        if scanned.key_order[index] ~= modname then
            fail("browser provider titan.a module #" .. index .. " is '" ..
                tostring(scanned.key_order[index]) .. "', expected '" .. modname .. "'")
        end
    end
    copy_file_atomic(staged_provider, assets.provider, false)

    -- Collect all installed browser SDK inputs for sdk-digests (written LAST).
    local digest_inputs = {
        descriptor.paths.liblua,
        descriptor.paths.lua_record,
    }
    local lua_headers, list_err = strategy:list(descriptor.paths.lua_source)
    if not lua_headers then fail(list_err) end
    table.sort(lua_headers, util.bytewise_less)
    for _, name in ipairs(lua_headers) do
        if name:match("^[^/\\]+[.]h$") then
            digest_inputs[#digest_inputs + 1] = paths.join(descriptor.paths.lua_source, name)
        end
    end
    for _, rel in ipairs({ "minicoro.h", "titan.h", "transfer.h", "titan/ffi.h", "titan/browser.h" }) do
        digest_inputs[#digest_inputs + 1] = paths.join(descriptor.paths.include, rel)
    end
    for _, key in ipairs({
        "runtime", "js_library", "bridge_library", "trace_library", "loader", "runner",
        "runner_module", "node_worker", "page", "lpeglabel", "provider",
    }) do
        local asset_path = assets[key]
        if lfs.attributes(asset_path, "mode") ~= "file" then
            fail("missing staged browser SDK asset '" .. asset_path .. "'")
        end
        digest_inputs[#digest_inputs + 1] = asset_path
    end

    local digest_ctx = {
        io = strategy,
        cache_adapter = {
            sha256_binary = support._sha256_binary,
            sha256_stream = support._sha256_stream,
        },
    }
    assert(incremental.write_sdk_digests(digest_ctx, assets.sdk_digests, digest_inputs))
    assert(driver.close_resolver_context(context))
else
    fail("unknown action: " .. tostring(action))
end

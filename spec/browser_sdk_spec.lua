local assert = require "luassert"
local lfs = require "lfs"
local browser = require "titan-compiler.browsertarget"
local browserlink = require "titan-compiler.browserlink"
local driver = require "titan-compiler.driver"
local incremental = require "titan-compiler.incremental"
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local version = require "titan-compiler.version"
local fixtures = require "spec.support.browser_fixtures"
local toolchain = require "spec.support.browser_toolchain"
local installed_prefix = require "spec.support.installed_prefix"
local temporary = require "spec.support.temporary"
local files = require "spec.fixtures.target_selection.support"

local EXPECTED_RUNTIME_MEMBERS = {
    "titan.o", "minicoro.o", "titan_path.o", "ltitanlib.o",
}

local EXPECTED_LPEGLABEL_MEMBERS = {
    "lplcap.o", "lplcode.o", "lplprint.o", "lpltree.o", "lplvm.o",
}

local EXPECTED_LPEGLABEL_SYMBOLS = {
    titan_lpeglabel_checkaux = true,
    titan_lpeglabel_compile = true,
    titan_lpeglabel_finddyncap = true,
    titan_lpeglabel_fixedlen = true,
    titan_lpeglabel_getcaptures = true,
    titan_lpeglabel_hascaptures = true,
    titan_lpeglabel_lp_gc = true,
    titan_lpeglabel_match = true,
    titan_lpeglabel_numsiblings = true,
    titan_lpeglabel_open = true,
    titan_lpeglabel_realloccode = true,
    titan_lpeglabel_runtimecap = true,
    titan_lpeglabel_sizei = true,
    titan_lpeglabel_tocharset = true,
}

local EXPECTED_PROVIDER_MODULES = {
    "titan.async", "titan.browser", "titan.coroutine", "titan.gc", "titan.http", "titan.io", "titan.iteration",
    "titan.json", "titan.lua", "titan.math", "titan.os", "titan.path", "titan.peg", "titan.protobuf",
    "titan.reflect", "titan.string", "titan.test", "titan.timer", "titan.transfer", "titan.url",
}

local function contains(text, fragment)
    assert.is_string(text)
    assert.truthy(text:find(fragment, 1, true), text)
end

local function run_with_env(strategy, env, argv)
    local full_argv = { "env" }
    local keys = {}
    for k in pairs(env or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        full_argv[#full_argv + 1] = k .. "=" .. tostring(env[k])
    end
    for _, arg in ipairs(argv) do full_argv[#full_argv + 1] = arg end
    return strategy:run(full_argv, { stderr_to_stdout = true })
end

local function copy_tree(strategy, source, destination)
    local info = assert(strategy:lstat(source), "missing source: " .. source)
    if info.kind == "file" then
        files.mkdir(assert(paths.dirname(destination)))
        local bytes = assert(strategy:read_file(source))
        assert(strategy:write_file(destination, bytes))
        if not platform.windows and strategy:executable(source) then
            assert(strategy:run({ "chmod", "0755", destination }, { stderr_to_stdout = true }).ok)
        end
    elseif info.kind == "directory" then
        files.mkdir(destination)
        for _, name in ipairs(assert(strategy:list(source))) do
            copy_tree(strategy, paths.join(source, name), paths.join(destination, name))
        end
    end
end

local function assert_no_forbidden_symbols(archive_name, archive)
    for _, member in ipairs(archive.members or {}) do
        local object = member.object
        assert.equal("wasm", object.format)
        for _, import in ipairs(object.imports or {}) do
            assert.not_equal("GOT.mem", import.module, archive_name .. " has PIC GOT.mem import")
            assert.not_equal("GOT.func", import.module, archive_name .. " has PIC GOT.func import")
            assert.not_equal("dlopen", import.name)
            assert.not_equal("dlsym", import.name)
            assert.not_equal("dlerror", import.name)
            assert.is_nil(tostring(import.name):match("^_?_?backtrace_"))
        end
        for _, symbol in ipairs(object.symbols or {}) do
            if not symbol.defined then
                assert.not_equal("dlopen", symbol.name)
                assert.not_equal("dlsym", symbol.name)
                assert.not_equal("dlerror", symbol.name)
                assert.is_nil(tostring(symbol.name):match("^_?_?backtrace_"))
            end
        end
    end
end

describe("browser SDK layout, Make rules, and bootstrap", function()
    local strategy = compiler_io.new_sync()
    local repository = assert(strategy:cwd())
    local workspace

    after_each(function()
        if workspace then
            files.remove(workspace)
            workspace = nil
        end
    end)

    local function new_workspace(suffix)
        workspace = temporary.name(suffix or "-browser-sdk")
        os.remove(workspace)
        files.mkdir(workspace)
        workspace = paths.to_slash(assert(strategy:realpath(workspace)))
        return workspace
    end

    it("declares lua-browser and browser-sdk only in POSIX Makefile and keeps Makefile.win free of browser targets", function()
        local makefile = assert(strategy:read_file(paths.join(repository, "Makefile")))
        local makefile_win = assert(strategy:read_file(paths.join(repository, "Makefile.win")))

        contains(makefile, "lua-browser:")
        contains(makefile, "browser-sdk:")
        contains(makefile, "scripts/lua_browser.sh")
        contains(makefile, "scripts/browser_sdk.lua")
        contains(makefile, "--print-c-objects")

        -- Ordinary Make targets must not invoke lua-browser or browser-sdk or inherit TITAN_TARGET.
        local all_rule = assert(makefile:match("\nall:[^\n]*\n\t([^\n]+)"))
        assert.is_nil(all_rule:find("lua-browser", 1, true))
        assert.is_nil(all_rule:find("browser-sdk", 1, true))
        contains(makefile, "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET;")

        assert.is_nil(makefile_win:find("lua%-browser"))
        assert.is_nil(makefile_win:find("browser%-sdk"))
    end)

    it("maps browser SDK assets into the sibling lib/titan-browser/<ver>/ tree and diagnoses missing required assets in order", function()
        local root = platform.windows and "C:/sdk-root" or "/sdk-root"
        local installed = driver.installed_paths(root, "browser")
        local native = driver.installed_paths(root, "linux")
        assert.not_equal(native.titan_bin, installed.titan_bin)
        assert.equal(root .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION,
            paths.to_slash(installed.titan_bin))

        local assets = browserlink.sdk_assets(installed)
        local slashed_assets = {}
        for key, value in pairs(assets) do
            slashed_assets[key] = paths.to_slash(paths.normalize(value))
        end
        local expected_bin = paths.to_slash(paths.normalize(installed.titan_bin))
        assert.same({
            runtime = expected_bin .. "/libtitan.a",
            js_library = expected_bin .. "/titan-browser-library.js",
            bridge_library = expected_bin .. "/titan-browser-bridge.js",
            trace_library = expected_bin .. "/titan-browser-trace.js",
            loader = expected_bin .. "/titan-browser.mjs",
            runner = expected_bin .. "/titan-browser-run",
            runner_module = expected_bin .. "/titan-browser-run.mjs",
            node_worker = expected_bin .. "/titan-browser-node-worker.mjs",
            page = expected_bin .. "/titan-browser-page.mjs",
            lpeglabel = expected_bin .. "/libtitan-lpeglabel.a",
            provider = expected_bin .. "/titan.a",
            sdk_digests = expected_bin .. "/sdk-digests",
        }, slashed_assets)

        local descriptor = assert(browser.import(fixtures.descriptor(root)))
        local descriptor_assets = browserlink.sdk_assets(descriptor.paths)
        local present = {}
        local function norm_key(filename)
            return paths.to_slash(paths.normalize(filename))
        end
        local fake_io = {
            stat = function(_, filename)
                local content = present[norm_key(filename)]
                if content then return { kind = "file", size = #content } end
                return nil
            end,
            read_file = function(_, filename)
                local content = present[norm_key(filename)]
                return content, content == nil and "missing" or nil
            end,
        }
        local required_order = {
            "runtime", "js_library", "bridge_library", "trace_library", "loader", "runner",
            "runner_module", "node_worker", "page",
        }
        for _, key in ipairs(required_order) do
            local ok, err = browserlink.require_sdk({ io = fake_io }, descriptor, { prefix = root })
            assert.is_nil(ok)
            assert.equal(
                string.format('browser SDK is incomplete: missing %q; run \'make browser-sdk PREFIX=%s\'',
                    descriptor_assets[key], root),
                err)
            local ok_empty_tree, err_empty_tree = browserlink.require_sdk({ io = fake_io }, descriptor, {
                prefix = root,
                rocks_tree = "",
            })
            assert.is_nil(ok_empty_tree)
            assert.equal(
                string.format('browser SDK is incomplete: missing %q; run \'make browser-sdk PREFIX=%s\'',
                    descriptor_assets[key], root),
                err_empty_tree)
            local ok_tree, err_tree = browserlink.require_sdk({ io = fake_io }, descriptor, {
                prefix = root,
                rocks_tree = root .. "-rocks",
            })
            assert.is_nil(ok_tree)
            assert.equal(
                string.format('browser SDK is incomplete: missing %q; run \'make browser-sdk PREFIX=%s ROCKS_TREE=%s\'',
                    descriptor_assets[key], root, root .. "-rocks"),
                err_tree)
            present[norm_key(descriptor_assets[key])] = "ok"
        end

        -- lpeglabel, provider, and sdk_digests are not bootstrap readiness prerequisites.
        local ready, ready_err = browserlink.require_sdk({ io = fake_io }, descriptor, { prefix = root })
        assert.same(descriptor_assets, ready, ready_err)
    end)

    it("runs the portable peer tests against the staged SDK module under Node", function()
        local info, why = toolchain.require({ node = true, sdk = true })
        if not info then pending(why) return end
        local peer = paths.join(info.sdk_root, "titan-protobuf.mjs")
        local source = assert(strategy:read_file(paths.join(repository, "titan-runtime/browser/titan-protobuf.mjs")))
        local rebuild = "staged portable peer is missing or stale; run 'make browser-sdk PREFIX=" .. info.prefix .. "'"
        local staged = assert(strategy:read_file(peer), rebuild)
        assert.equal(source, staged, rebuild)
        local result = strategy:run({
            info.node.path, "--input-type=module", "-e", [[
import { pathToFileURL } from 'node:url';
const { peerTests } = await import(pathToFileURL(process.argv[1]));
console.log(`portable peer: ${await peerTests(pathToFileURL(process.argv[2]))} assertions passed`);
]], paths.join(repository, "spec/fixtures/browser_bridge/portable-peer.mjs"), peer,
        }, { stderr_to_stdout = true })
        assert.is_true(result.ok, result.output)
        local passed = result.output:match("(%d+) assertions passed")
        assert.truthy(passed and tonumber(passed) > 0, result.output)
    end)

    it("writes and reloads browser sdk-digests with schema 1 and invalidates modified entries", function()
        local root = new_workspace("-sdk-digests-unit")
        local browser_paths = driver.installed_paths(root, "browser")
        local assets = browserlink.sdk_assets(browser_paths)
        files.mkdir(browser_paths.lua_source)
        files.mkdir(paths.join(browser_paths.include, "titan"))
        files.mkdir(browser_paths.titan_bin)

        local inputs = {
            browser_paths.liblua,
            browser_paths.lua_record,
            paths.join(browser_paths.lua_source, "lua.h"),
            paths.join(browser_paths.lua_source, "luaconf.h"),
            paths.join(browser_paths.include, "minicoro.h"),
            paths.join(browser_paths.include, "titan.h"),
            paths.join(browser_paths.include, "transfer.h"),
            paths.join(browser_paths.include, "titan/ffi.h"),
            paths.join(browser_paths.include, "titan/browser.h"),
            assets.runtime,
            assets.js_library,
            assets.bridge_library,
            assets.trace_library,
            assets.loader,
            assets.runner,
            assets.runner_module,
            assets.node_worker,
            assets.page,
            assets.lpeglabel,
            assets.provider,
        }
        for index, filename in ipairs(inputs) do
            assert(strategy:write_file(filename, "payload-" .. tostring(index)))
        end

        local graphcodec = require "titan-compiler.graphcodec"
        local sha256 = require "titan-compiler.sha256"
        local support = require "titan"
        local ctx = {
            io = strategy,
            cache_adapter = {
                sha256_binary = support._sha256_binary,
                sha256_stream = support._sha256_stream,
            },
        }
        assert(incremental.write_sdk_digests(ctx, assets.sdk_digests, inputs))
        assert.equal("file", strategy:stat(assets.sdk_digests).kind)

        local raw_manifest = assert(strategy:read_file(assets.sdk_digests))
        local decoded = assert(graphcodec.decode(raw_manifest))
        assert.equal(version.SDK_DIGEST_SCHEMA, decoded.schema)
        assert.equal("1", decoded.schema)
        assert.equal(version.CERTIFICATE_DIGEST, decoded.digest)
        assert.equal(version.CERTIFICATE_CANONICALIZATION, decoded.canonicalization)
        assert.equal(version.TITAN_ABI_VERSION, decoded.abi)

        local reader_ctx = {
            io = strategy,
            cache_adapter = ctx.cache_adapter,
        }
        assert(incremental.load_sdk_digests(reader_ctx, assets.sdk_digests))
        local sdk_state = reader_ctx.incremental and reader_ctx.incremental.sdk
        assert.is_table(sdk_state)
        assert.is_nil(sdk_state.files[assert(strategy:realpath(assets.sdk_digests))])
        for _, filename in ipairs(inputs) do
            local real = assert(strategy:realpath(filename))
            assert.is_table(sdk_state.files[real], "missing sdk-digests entry for " .. filename)
            local expected_hex = sha256.hex_via(support._sha256_binary, assert(strategy:read_file(filename)))
            assert.equal(expected_hex, sdk_state.files[real].digest)
            assert.equal(expected_hex, incremental.file_digest(reader_ctx, filename))
        end
        assert.equal(#inputs, incremental.counters(reader_ctx).sdk_reuses)
        assert.equal(0, incremental.counters(reader_ctx).file_reads)

        -- Modifying an entry invalidates its recorded observation and re-hashes from disk.
        assert(strategy:write_file(assets.loader, "modified-loader-payload-after-digest"))
        local modified_ctx = {
            io = strategy,
            cache_adapter = ctx.cache_adapter,
        }
        assert(incremental.load_sdk_digests(modified_ctx, assets.sdk_digests))
        local new_digest = incremental.file_digest(modified_ctx, assets.loader)
        assert.equal(
            sha256.hex_via(support._sha256_binary, "modified-loader-payload-after-digest"),
            new_digest)
        assert.equal(0, incremental.counters(modified_ctx).sdk_reuses)
        assert.equal(1, incremental.counters(modified_ctx).file_reads)
    end)

    it("bootstraps lfs and compiler modules from TITAN_INSTALL_TREE before PREFIX and rejects incomplete PREFIX browser Lua", function()
        if platform.windows then
            pending("POSIX browser_sdk.lua bootstrap test")
            return
        end
        local active_prefix = installed_prefix.active()
        local root = new_workspace("-sdk-bootstrap-order")
        local bare_prefix = paths.join(root, "bare-prefix")
        local rocks_tree = paths.join(root, "rocks-tree")
        local fake_em = paths.join(root, "emscripten")
        files.mkdir(paths.join(bare_prefix, "bin"))
        files.mkdir(fake_em)

        -- Populate rocks_tree with lfs.so, titan.so, and titan-compiler Lua modules,
        -- while leaving bare_prefix without lfs.so or titan.so.
        copy_tree(strategy, paths.join(active_prefix, "lib/lua/5.5"), paths.join(rocks_tree, "lib/lua/5.5"))
        copy_tree(strategy, paths.join(active_prefix, "share/lua/5.5"), paths.join(rocks_tree, "share/lua/5.5"))
        copy_tree(strategy, paths.join(active_prefix, "include"), paths.join(rocks_tree, "include"))

        -- Put a shadowed poisoned module in bare_prefix to prove TITAN_INSTALL_TREE wins over PREFIX.
        files.mkdir(paths.join(bare_prefix, "share/lua/5.5/titan-compiler"))
        assert(strategy:write_file(
            paths.join(bare_prefix, "share/lua/5.5/titan-compiler/browserlink.lua"),
            'error("WRONG_ROOT_PRECEDENCE: PREFIX loaded before TITAN_INSTALL_TREE", 0)\n'))

        -- Put a stale browser Lua installation in rocks_tree, while bare_prefix has no lib/browser.
        local sentinel = paths.join(rocks_tree, "lib/browser/stale_sentinel.txt")
        files.mkdir(paths.join(rocks_tree, "lib/browser/include"))
        assert(strategy:write_file(sentinel, "keep-existing-tree"))
        local _, rec_text, ar_bytes, hdrs = fixtures.record()
        assert(strategy:write_file(paths.join(rocks_tree, "lib/browser/liblua-config.txt"), rec_text))
        assert(strategy:write_file(paths.join(rocks_tree, "lib/browser/liblua.a"), ar_bytes))
        for name, content in pairs(hdrs) do
            assert(strategy:write_file(paths.join(rocks_tree, "lib/browser/include/" .. name), content))
        end

        for _, tool in ipairs({ "emcc", "emar", "emranlib" }) do
            local p = paths.join(fake_em, tool)
            assert(strategy:write_file(p, "#!/bin/sh\necho 'emcc (Emscripten) 6.0.13'\n"))
            assert(strategy:run({ "chmod", "0755", p }, { stderr_to_stdout = true }).ok)
        end

        local res = run_with_env(strategy, {
            PATH = fake_em .. ":/usr/bin:/bin",
            EMSDK = "",
            PREFIX = bare_prefix,
            TITAN_INSTALL_TREE = rocks_tree,
            ROCKS_TREE = rocks_tree,
        }, {
            paths.join(active_prefix, "bin/lua"), "-E",
            paths.join(repository, "scripts/browser_sdk.lua"),
            "prepare", paths.join(root, "build"),
        })
        assert.is_false(res.ok)
        assert.is_nil(res.output:find("WRONG_ROOT_PRECEDENCE", 1, true), res.output)
        assert.is_nil(res.output:find("LuaFileSystem", 1, true), res.output)
        contains(res.output, bare_prefix .. "/lib/browser/liblua-config.txt")
        contains(res.output, "make install-browser PREFIX=" .. bare_prefix)
        -- Existing destination files were not deleted or consumed.
        assert.equal("keep-existing-tree", strategy:read_file(sentinel))
    end)

    it("reuses a warm matching lua-browser installation and rebuilds on config, archive, or header changes", function()
        local info, why = toolchain.require()
        if not info then pending(why) return end

        local root = new_workspace("-lua-browser-reuse")
        local temp_lua = paths.join(root, "lua-5.5.1")
        local temp_prefix = paths.join(root, "prefix")
        copy_tree(strategy, paths.join(repository, "lua-5.5.1/Makefile"), paths.join(temp_lua, "Makefile"))
        copy_tree(strategy, paths.join(repository, "lua-5.5.1/src"), paths.join(temp_lua, "src"))
        copy_tree(strategy, paths.join(repository, "lua-5.5.1/tools"), paths.join(temp_lua, "tools"))

        local record_bytes = assert(strategy:read_file(info.record_path))
        local fork_rev = assert(record_bytes:match("fork_revision=([0-9a-f]+)"))
        local em_dir = paths.dirname(info.tools.cc[1])
        local base_env = {
            PATH = em_dir .. ":" .. (os.getenv("PATH") or ""),
            FORK_REVISION = fork_rev,
            CCACHE_DISABLE = "1",
        }

        local function run_lua_browser(extra_args)
            local argv = {
                "make", "--no-print-directory", "lua-browser",
                "PREFIX=" .. temp_prefix,
                "LUA_DIR=" .. temp_lua,
                "FORK_REVISION=" .. fork_rev,
            }
            for _, arg in ipairs(extra_args or {}) do argv[#argv + 1] = arg end
            return run_with_env(strategy, base_env, argv)
        end

        -- 1. Cold build and install into temp_prefix.
        local first = run_lua_browser()
        assert.is_true(first.ok, first.output)
        local liblua = paths.join(temp_prefix, "lib/browser/liblua.a")
        local record = paths.join(temp_prefix, "lib/browser/liblua-config.txt")
        local lua_h = paths.join(temp_prefix, "lib/browser/include/lua.h")
        local lapi_o = paths.join(temp_lua, "src/browser/obj/lapi.o")

        local stat_liblua_1 = assert(strategy:stat(liblua))
        local stat_record_1 = assert(strategy:stat(record))
        local stat_luah_1 = assert(strategy:stat(lua_h))
        local stat_lapio_1 = assert(strategy:stat(lapi_o))
        local clean_liblua_bytes = assert(strategy:read_file(liblua))
        local clean_record_bytes = assert(strategy:read_file(record))
        local clean_luah_bytes = assert(strategy:read_file(lua_h))
        contains(clean_record_bytes, "sjlj=wasm\n")
        contains(clean_record_bytes, "+exception-handling")
        contains(clean_record_bytes, "-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1")

        -- 2. Warm matching configuration is reused without touching installed or object files,
        -- and explicit empty LUA_BROWSER_MYCFLAGS= overrides ambient MYCFLAGS.
        local warm = run_lua_browser({ "MYCFLAGS=-fPIC", "LUA_BROWSER_MYCFLAGS=" })
        assert.is_true(warm.ok, warm.output)
        assert.same(stat_liblua_1, assert(strategy:stat(liblua)))
        assert.same(stat_record_1, assert(strategy:stat(record)))
        assert.same(stat_luah_1, assert(strategy:stat(lua_h)))
        assert.same(stat_lapio_1, assert(strategy:stat(lapi_o)))

        -- 3. Corrupted installed archive AND truncated/corrupted build-tree archive (preserving !<arch>\n)
        -- are both reconstructed from objects rather than blessing corrupt bytes.
        local sha256 = require "titan-compiler.sha256"
        local support = require "titan"
        local corrupt_archive = "!<arch>\ncorrupted-wasm-archive-bytes"
        local forged_sha = sha256.hex_via(support._sha256_binary, corrupt_archive)
        local build_liblua = paths.join(temp_lua, "src/browser/liblua.a")
        assert(strategy:write_file(build_liblua, corrupt_archive))
        assert(strategy:write_file(liblua, corrupt_archive))
        assert(strategy:write_file(record, (clean_record_bytes:gsub("archive_sha256=[0-9a-f]+", "archive_sha256=" .. forged_sha))))
        local after_archive_corrupt = run_lua_browser()
        assert.is_true(after_archive_corrupt.ok, after_archive_corrupt.output)
        assert.equal(clean_liblua_bytes, assert(strategy:read_file(build_liblua)))
        assert.equal(clean_liblua_bytes, assert(strategy:read_file(liblua)))
        assert.equal(clean_record_bytes, assert(strategy:read_file(record)))

        -- 4. Malformed records and records for the previous JS-SJLJ or implicit
        -- EH encoding configuration are rejected and regenerated cleanly.
        for _, bad_record in ipairs({
            clean_record_bytes:sub(1, -2),
            clean_record_bytes .. "# trailing comment not allowed\n",
            (clean_record_bytes:gsub("\n", "\r\n", 1)),
            clean_record_bytes:sub(1, -2) .. "\0\n",
            clean_record_bytes:sub(1, -2) .. "\255\n",
            (clean_record_bytes:gsub("sjlj=wasm", "sjlj=emscripten")),
            (clean_record_bytes:gsub(" %-sWASM_LEGACY_EXCEPTIONS=1", "")),
            (clean_record_bytes:gsub("WASM_LEGACY_EXCEPTIONS=1", "WASM_LEGACY_EXCEPTIONS=0")),
            (clean_record_bytes:gsub(" %+exception%-handling", "")),
        }) do
            assert(strategy:write_file(record, bad_record))
            local repaired = run_lua_browser()
            assert.is_true(repaired.ok, repaired.output)
            assert.equal(clean_record_bytes, assert(strategy:read_file(record)))
        end

        -- 5. Corrupted installed header and extra header file are repaired from source.
        local stale_h = paths.join(temp_prefix, "lib/browser/include/stale_extra.h")
        assert(strategy:write_file(lua_h, clean_luah_bytes .. "\n/* corrupted header */\n"))
        assert(strategy:write_file(stale_h, "/* should be removed */\n"))
        local after_header_corrupt = run_lua_browser()
        assert.is_true(after_header_corrupt.ok, after_header_corrupt.output)
        assert.equal(clean_luah_bytes, assert(strategy:read_file(lua_h)))
        assert.is_nil(strategy:stat(stale_h))
        assert.equal(clean_record_bytes, assert(strategy:read_file(record)))

        -- 6. Same fork revision with changed configuration rebuilds objects and updates record.
        local changed_cfg = run_lua_browser({ "LUA_BROWSER_MYCFLAGS=-DLUA_USER_DEFAULT=1" })
        assert.is_true(changed_cfg.ok, changed_cfg.output)
        local updated_record = assert(strategy:read_file(record))
        contains(updated_record, "fork_revision=" .. fork_rev)
        contains(updated_record, "lua_defines=-DLUAI_MAXCCALLS=100 -DLUA_USER_DEFAULT=1 -DLUA_USE_BROWSER -DLUA_USE_POSIX")
        contains(updated_record, "cflags=-O2 -Wall -Wextra -DLUA_USE_POSIX -DLUA_USE_BROWSER " ..
            "-DLUAI_MAXCCALLS=100 -sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1 -DLUA_USER_DEFAULT=1")

        local updated_liblua = assert(strategy:read_file(liblua))
        -- Inspect wrong effective settings using the real installer and an
        -- existing archive: rejection must precede installation, not bless it
        -- with a new record. This does not rebuild a Lua archive per bad flag.
        local configuration = paths.join(root, "rejected-config")
        for _, flag in ipairs({ "-sSUPPORT_LONGJMP=emscripten", "-s SUPPORT_LONGJMP=emscripten",
                "-sSUPPORT_LONGJMP", "-sNO_SUPPORT_LONGJMP=1",
                "-sWASM_LEGACY_EXCEPTIONS=0", "-s WASM_LEGACY_EXCEPTIONS=0",
                "-sNO_WASM_LEGACY_EXCEPTIONS", "-s NO_WASM_LEGACY_EXCEPTIONS=1",
                "-mno-exception-handling" }) do
            local config = run_with_env(strategy, base_env, {
                "make", "-s", "--no-print-directory", "-C", paths.join(temp_lua, "src"),
                "browser-config", "BROWSER_CC=" .. info.tools.cc[1], "MYCFLAGS=" .. flag,
            })
            assert.is_true(config.ok, config.output)
            local config_text, replacements = config.output:gsub("browser_src= %.\n",
                "browser_src= " .. paths.join(temp_lua, "src") .. "\n")
            assert.equal(1, replacements)
            assert(strategy:write_file(configuration, config_text))
            local rejected = run_with_env(strategy, base_env, {
                "sh", "-c", 'exec sh "$1" "$2" < "$3"', "sh",
                paths.join(temp_lua, "tools/install-browser.sh"),
                paths.join(temp_prefix, "lib/browser"), configuration,
            })
            assert.is_false(rejected.ok, rejected.output)
            contains(rejected.output, "install-browser: the browser build")
            assert.equal(updated_record, strategy:read_file(record))
            assert.equal(updated_liblua, strategy:read_file(liblua))
        end
    end)

    it("clears ambient EMCC_CFLAGS in fork browser entrypoints and reuse without changing native goals", function()
        local info, why = toolchain.require()
        if not info then pending(why) return end
        local root = new_workspace("-lua-browser-ambient")
        local temp_lua = paths.join(root, "lua-5.5.1")
        local temp_prefix = paths.join(root, "prefix")
        for _, name in ipairs({ "Makefile", "src", "tools" }) do
            copy_tree(strategy, paths.join(repository, "lua-5.5.1", name), paths.join(temp_lua, name))
        end
        local revision = assert(assert(strategy:read_file(info.record_path)):match("fork_revision=([0-9a-f]+)"))
        local guarded_cc = paths.join(root, "guarded-emcc")
        local native_cc = paths.join(root, "native-cc")
        assert(strategy:write_file(guarded_cc, [[#!/bin/sh
set -eu
[ -z "${EMCC_CFLAGS:-}" ] || { echo "ambient EMCC_CFLAGS reached browser compiler" >&2; exit 91; }
exec "$TITAN_TEST_REAL_EMCC" "$@"
]]))
        assert(strategy:write_file(native_cc, [[#!/bin/sh
set -eu
[ "${EMCC_CFLAGS-}" = "$TITAN_TEST_EXPECT_EMCC_CFLAGS" ] || { echo "native environment changed" >&2; exit 92; }
exec cc "$@"
]]))
        assert(strategy:run({ "chmod", "0755", guarded_cc, native_cc }).ok)
        for _, ambient in ipairs({ "-sWASM_LEGACY_EXCEPTIONS=0", "-sSUPPORT_LONGJMP=emscripten" }) do
            local env = {
                PATH = paths.dirname(info.tools.cc[1]) .. ":" .. (os.getenv("PATH") or ""),
                EMCC_CFLAGS = ambient, TITAN_TEST_EXPECT_EMCC_CFLAGS = ambient,
                TITAN_TEST_REAL_EMCC = info.tools.cc[1], FORK_REVISION = revision, CCACHE_DISABLE = "1",
            }
            local function run_make(directory, arguments)
                local argv = { "make", "--no-print-directory", "-C", directory }
                for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
                return run_with_env(strategy, env, argv)
            end
            local compiled = run_make(paths.join(temp_lua, "src"), {
                "-B", "browser", "BROWSER_CC=" .. guarded_cc,
            })
            assert.is_true(compiled.ok, compiled.output)
            local config = run_make(paths.join(temp_lua, "src"), {
                "-s", "browser-config", "BROWSER_CC=" .. guarded_cc,
            })
            assert.is_true(config.ok, config.output)
            local config_text, replacements = config.output:gsub("browser_src= %.\n",
                "browser_src= " .. paths.join(temp_lua, "src") .. "\n")
            assert.equal(1, replacements)
            local config_path = paths.join(root, "browser-config")
            assert(strategy:write_file(config_path, config_text))
            local installed = run_with_env(strategy, env, {
                "sh", "-c", 'exec sh "$1" "$2" < "$3"', "sh",
                paths.join(temp_lua, "tools/install-browser.sh"),
                paths.join(temp_prefix, "lib/browser"), config_path,
            })
            assert.is_true(installed.ok, installed.output)
            local delegated = run_make(temp_lua, {
                "install-browser", "PREFIX=" .. temp_prefix, "BROWSER_CC=" .. guarded_cc,
            })
            assert.is_true(delegated.ok, delegated.output)
            local archive = paths.join(temp_prefix, "lib/browser/liblua.a")
            local before = assert(strategy:stat(archive))
            local reused = run_with_env(strategy, env, {
                "make", "--no-print-directory", "lua-browser", "PREFIX=" .. temp_prefix,
                "LUA_DIR=" .. temp_lua, "LUA_BROWSER_CC=" .. guarded_cc,
                "LUA_BROWSER_AR=" .. info.tools.ar[1] .. " rcu",
                "LUA_BROWSER_RANLIB=" .. info.tools.ranlib[1],
            })
            assert.is_true(reused.ok, reused.output)
            assert.same(before, assert(strategy:stat(archive)))
            local record = assert(strategy:read_file(paths.join(temp_prefix, "lib/browser/liblua-config.txt")))
            contains(record, "sjlj=wasm\n")
            contains(record, "-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1")
            local native = run_make(paths.join(temp_lua, "src"), { "-B", "lapi.o", "CC=" .. native_cc })
            assert.is_true(native.ok, native.output)
        end
    end)

    it("installs browser-sdk into an empty differing ROCKS_TREE, verifies archives/digests/stack size, and keeps compiler SDK emsdk-free", function()
        local info, why = toolchain.require({ node = true })
        if not info then pending(why) return end

        local root = new_workspace("-browser-sdk-e2e")
        local rocks_tree = paths.join(root, "empty-rocks-tree")
        local build_dir = paths.join(root, "browser-build")
        local app_dir = paths.join(root, "app")
        local app_out = paths.join(root, "app-out")
        files.mkdir(app_dir)
        files.mkdir(app_out)

        local em_dir = paths.dirname(info.tools.cc[1])
        local node_dir = paths.dirname(info.node.path)
        local sdk_env = {
            PATH = em_dir .. ":" .. node_dir .. ":" .. (os.getenv("PATH") or ""),
            TITAN_NODE = info.node.path,
            CCACHE_DISABLE = "1",
        }

        -- 1. Before browser-sdk: C-only --c-source work succeeds without lib/titan-browser,
        -- while linking a program fails with the exact missing-SDK diagnostic naming make browser-sdk.
        assert(strategy:write_file(paths.join(app_dir, "helper.c"), "int browser_sdk_c_only(void) { return 7; }\n"))
        assert(strategy:write_file(paths.join(app_dir, "main_app.titan"), [[
local coroutine = import "coroutine"
local test = import "test"
foreign import "titan.h"

local function body(): integer
    local lj = L.errorJmp
    while lj.previous ~= nil do
        lj = lj.previous
    end
    local floor = lj as foreign *titan_unwind_floor
    local span = (floor.stack_high as integer) - (floor.stack_low as integer)
    if span ~= (ffi.TITAN_COROUTINE_STACK_SIZE as integer) then
        return -1
    end
    return span
end

function test_browser_coroutine_stack(_context: test.Context)
    local co = coroutine.create(body, "sdk-tag")
    local res: integer = co:resume()
    test.assert(res == 262144, "expected 256 KiB browser coroutine stack allocation and macro")
end
]]))

        local no_sdk_root = paths.join(root, "no-sdk-tree")
        copy_tree(strategy, paths.join(info.prefix, "lib/browser"), paths.join(no_sdk_root, "lib/browser"))
        copy_tree(strategy, paths.join(info.prefix, "include"), paths.join(no_sdk_root, "include"))

        local c_only_res = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            TITAN_ROOT = no_sdk_root,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser",
            "--output", app_out, "-c", "--incremental", "--print-c-objects",
            "--c-source", paths.join(app_dir, "helper.c"),
        })
        assert.is_true(c_only_res.ok, c_only_res.output)
        local c_obj_path = assert(c_only_res.output:match("([^\r\n]+)[\r\n]*$"))
        assert.equal("file", strategy:stat(c_obj_path).kind)

        local link_missing_res = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            PREFIX = info.prefix,
            ROCKS_TREE = no_sdk_root,
            TITAN_ROOT = no_sdk_root,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser",
            "--tree", app_dir .. ";" .. repository, "--output", app_out,
            "--exe", paths.join(app_out, "app.mjs"),
            "--test", "main_app",
        })
        assert.is_false(link_missing_res.ok)
        contains(link_missing_res.output,
            string.format('browser SDK is incomplete: missing %q; run \'make browser-sdk PREFIX=%s ROCKS_TREE=%s\'',
                no_sdk_root .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION .. "/libtitan.a",
                no_sdk_root, no_sdk_root))

        local link_empty_rocks_res = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            PREFIX = info.prefix,
            ROCKS_TREE = "",
            TITAN_ROOT = no_sdk_root,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser",
            "--tree", app_dir .. ";" .. repository, "--output", app_out,
            "--exe", paths.join(app_out, "app.mjs"),
            "--test", "main_app",
        })
        assert.is_false(link_empty_rocks_res.ok)
        contains(link_empty_rocks_res.output,
            string.format('browser SDK is incomplete: missing %q; run \'make browser-sdk PREFIX=%s\'',
                no_sdk_root .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION .. "/libtitan.a",
                no_sdk_root))
        assert.is_nil(link_empty_rocks_res.output:find("ROCKS_TREE=", 1, true), link_empty_rocks_res.output)

        -- An explicit old Node is diagnosed. An old EMSDK-bundled Node must
        -- not override the qualifying Node selected through ordinary PATH.
        local fake_node_dir = paths.join(root, "fake-node24")
        local good_node_dir = paths.join(root, "node26")
        local fake_emsdk = paths.join(root, "fake-emsdk")
        local fake_emsdk_node_dir = paths.join(fake_emsdk, "node/24.19.0_64bit/bin")
        files.mkdir(fake_node_dir)
        files.mkdir(fake_emsdk_node_dir)
        files.mkdir(good_node_dir)
        local bad_node = paths.join(fake_node_dir, "node")
        assert(strategy:write_file(bad_node, "#!/bin/sh\necho 'v24.19.0'\n"))
        assert(strategy:run({ "chmod", "0755", bad_node }, { stderr_to_stdout = true }).ok)
        assert(lfs.link(bad_node, paths.join(fake_emsdk_node_dir, "node"), true))
        assert(lfs.link(info.node.path, paths.join(good_node_dir, "node"), true))
        assert(lfs.link(paths.dirname(em_dir), paths.join(fake_emsdk, "upstream"), true))

        local bad_node_res = run_with_env(strategy, {
            PATH = em_dir .. ":" .. (os.getenv("PATH") or ""),
            TITAN_NODE = bad_node,
            CCACHE_DISABLE = "1",
        }, {
            "make", "--no-print-directory", "browser-sdk",
            "PREFIX=" .. info.prefix,
            "ROCKS_TREE=" .. rocks_tree,
            "TITAN_BROWSER_BUILD_DIR=" .. build_dir,
            "TITAN_BUILD_PROFILE=validation",
        })
        assert.is_false(bad_node_res.ok)
        contains(bad_node_res.output,
            string.format('browser provider validation requires Node 26 or newer: %q reports v24.19.0; expected Node 26 or newer; set TITAN_NODE to a Node 26 or newer executable',
                assert(strategy:realpath(bad_node))))

        -- Run into an empty differing ROCKS_TREE with Node 26 on PATH.
        local sdk_res = run_with_env(strategy, {
            PATH = good_node_dir .. ":" .. fake_node_dir .. ":" .. em_dir .. ":" .. (os.getenv("PATH") or ""),
            EMSDK = fake_emsdk,
            TITAN_NODE = "",
            CCACHE_DISABLE = "1",
            -- Both ambient spellings must be replaced, not appended to the
            -- browser provider's lpeglabel-only include policy.
            TITAN_EXTRA_CPPFLAGS = "-include /missing/ambient-titan-cppflags.h",
            CPPFLAGS = "-include /missing/ambient-cppflags.h",
        }, {
            "make", "--no-print-directory", "browser-sdk",
            "PREFIX=" .. info.prefix,
            "ROCKS_TREE=" .. rocks_tree,
            "TITAN_BROWSER_BUILD_DIR=" .. build_dir,
            "TITAN_BUILD_PROFILE=validation",
        })
        assert.is_true(sdk_res.ok, sdk_res.output)

        -- Native provider directory in rocks_tree must remain untouched/absent.
        assert.is_nil(strategy:stat(paths.join(rocks_tree, "lib/titan")))

        -- Staged browser Lua in rocks_tree matches PREFIX/lib/browser.
        local browser_paths = driver.installed_paths(rocks_tree, "browser")
        assert.equal(
            assert(strategy:read_file(paths.join(info.prefix, "lib/browser/liblua.a"))),
            assert(strategy:read_file(browser_paths.liblua)))
        assert.equal(
            assert(strategy:read_file(paths.join(info.prefix, "lib/browser/liblua-config.txt"))),
            assert(strategy:read_file(browser_paths.lua_record)))

        -- Common Titan headers were staged without copying native Lua headers into include/.
        for _, rel in ipairs({ "minicoro.h", "titan.h", "transfer.h", "titan/ffi.h", "titan/browser.h" }) do
            assert.equal("file", strategy:stat(paths.join(browser_paths.include, rel)).kind, rel)
        end
        assert.is_nil(strategy:stat(paths.join(browser_paths.include, "lua.h")))

        -- Inspect libtitan.a, libtitan-lpeglabel.a, and titan.a.
        local assets = browserlink.sdk_assets(browser_paths)
        assert.equal(
            assert(strategy:read_file(paths.join(repository, "titan-runtime/browser/titan-protobuf.mjs"))),
            assert(strategy:read_file(paths.join(browser_paths.titan_bin, "titan-protobuf.mjs"))))
        local expected_fp = fixtures.fingerprint()

        local runtime_ar = assert(staticmetadata.scan_archive(assets.runtime, { target = expected_fp }))
        local runtime_names = {}
        for i, m in ipairs(runtime_ar.members) do runtime_names[i] = m.display_name end
        assert.same(EXPECTED_RUNTIME_MEMBERS, runtime_names)
        assert_no_forbidden_symbols(assets.runtime, runtime_ar)

        local lpeg_ar = assert(staticmetadata.scan_archive(assets.lpeglabel, { target = expected_fp }))
        local lpeg_names = {}
        local lpeg_defined = {}
        for i, m in ipairs(lpeg_ar.members) do
            lpeg_names[i] = m.display_name
            for _, sym in ipairs(m.object.symbols or {}) do
                if sym.defined and sym.binding == "global" then
                    lpeg_defined[sym.name] = true
                end
            end
        end
        assert.same(EXPECTED_LPEGLABEL_MEMBERS, lpeg_names)
        for sym_name in pairs(EXPECTED_LPEGLABEL_SYMBOLS) do
            assert.is_true(lpeg_defined[sym_name], "missing LPegLabel symbol " .. sym_name)
        end
        assert_no_forbidden_symbols(assets.lpeglabel, lpeg_ar)

        local provider_ar = assert(staticmetadata.scan_archive(assets.provider, {
            expected_abi = version.TITAN_ABI_VERSION,
            target = expected_fp,
        }))
        assert(driver.validate_browser_provider(provider_ar))
        assert.same(EXPECTED_PROVIDER_MODULES, provider_ar.key_order)
        local compiler_members, native_payload_members = {}, {}
        for _, member in ipairs(provider_ar.members) do
            if member.object.metadata then
                local record = assert(objectmetadata.read(member.bytes, member.display_name))
                local stem = assert(member.display_name:match("^(.*)%.o$"))
                for _, part in ipairs(assert(record.object_metadata.parts)) do
                    compiler_members[stem .. part.object_suffix] = true
                end
            end
        end
        for _, member in ipairs(provider_ar.members) do
            if not compiler_members[member.display_name] then
                native_payload_members[#native_payload_members + 1] = member.display_name
            end
        end
        table.sort(native_payload_members)
        assert.same(EXPECTED_LPEGLABEL_MEMBERS, native_payload_members)
        assert_no_forbidden_symbols(assets.provider, provider_ar)
        assert.is_nil(strategy:stat(browser_paths.titan_bin .. "/titan.so"))
        assert.is_nil(strategy:stat(browser_paths.titan_bin .. "/titan.dll"))

        -- Verify sdk-digests was written last and covers the exact full installed file set
        -- (Lua archive/record/27 headers + 5 common Titan headers + browser SDK assets).
        local sha256 = require "titan-compiler.sha256"
        local support = require "titan"
        local digest_ctx = {
            io = strategy,
            cache_adapter = {
                sha256_binary = support._sha256_binary,
                sha256_stream = support._sha256_stream,
            },
        }
        assert(incremental.load_sdk_digests(digest_ctx, assets.sdk_digests))
        local recorded = assert(digest_ctx.incremental and digest_ctx.incremental.sdk)
        assert.is_nil(recorded.files[assert(strategy:realpath(assets.sdk_digests))])

        local expected_digest_files = {
            browser_paths.liblua,
            browser_paths.lua_record,
            paths.join(browser_paths.titan_bin, "titan-protobuf.mjs"),
        }
        local staged_lua_headers = assert(strategy:list(browser_paths.lua_source))
        table.sort(staged_lua_headers)
        assert.equal(27, #staged_lua_headers)
        for _, name in ipairs(staged_lua_headers) do
            expected_digest_files[#expected_digest_files + 1] = paths.join(browser_paths.lua_source, name)
        end
        for _, rel in ipairs({ "minicoro.h", "titan.h", "transfer.h", "titan/ffi.h", "titan/browser.h" }) do
            expected_digest_files[#expected_digest_files + 1] = paths.join(browser_paths.include, rel)
        end
        for _, key in ipairs({
            "runtime", "js_library", "bridge_library", "trace_library", "loader", "runner",
            "runner_module", "node_worker", "page", "lpeglabel", "provider",
        }) do
            expected_digest_files[#expected_digest_files + 1] = assets[key]
        end
        local expected_real_set = {}
        for _, filepath in ipairs(expected_digest_files) do
            local real = assert(strategy:realpath(filepath))
            expected_real_set[real] = true
            local entry = assert(recorded.files[real], "missing digest entry for " .. filepath)
            assert.equal(sha256.hex_via(support._sha256_binary, assert(strategy:read_file(real))), entry.digest)
            local live_obs = assert(incremental.observation(digest_ctx, real, false))
            assert.equal(live_obs.size, entry.observation.size)
            assert.equal(live_obs.mtime_ns, entry.observation.mtime_ns)
            assert.equal(live_obs.ino, entry.observation.ino)
        end
        local recorded_count = 0
        for real_key in pairs(recorded.files) do
            assert.is_true(expected_real_set[real_key], "unexpected sdk-digests key: " .. real_key)
            recorded_count = recorded_count + 1
        end
        assert.equal(#expected_digest_files, recorded_count)
        -- 3. Link and execute the test image against the newly staged ROCKS_TREE SDK.
        local test_exe = paths.join(app_out, "stack_test.mjs")
        local build_test = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            TITAN_NODE = info.node.path,
            PREFIX = info.prefix,
            ROCKS_TREE = rocks_tree,
            TITAN_ROOT = rocks_tree,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser", "-q",
            "--tree", app_dir, "--output", app_out, "--exe", test_exe,
            "--test", "main_app",
        })
        assert.is_true(build_test.ok, build_test.output)
        local run_test = run_with_env(strategy, sdk_env, {
            assets.runner, "--engine", "node", test_exe,
        })
        assert.is_true(run_test.ok, run_test.output)
        contains(run_test.output, "[       OK ] main_app.test_browser_coroutine_stack")
        contains(run_test.output, "[  PASSED  ] 1 test.")

        -- 3b. Publish a browser library from a catch-bearing Titan module plus a setjmp C helper
        -- alongside non-setjmp counterparts: Wasm SJLJ uses the same EH fingerprint without JS-SJLJ's -shared-mem marker.
        local sjlj_src = paths.join(root, "sjlj-src")
        local sjlj_out = paths.join(root, "sjlj-out")
        files.mkdir(paths.join(sjlj_src, "sjlj_pkg"))
        files.mkdir(sjlj_out)
        assert(strategy:write_file(paths.join(sjlj_src, "sjlj_helper.c"), [[
#include <setjmp.h>
int sjlj_c_helper(int x) {
    jmp_buf buf;
    if (setjmp(buf) == 0) {
        if (x < 0) longjmp(buf, 1);
        return x + 10;
    }
    return -1;
}
]]))
        assert(strategy:write_file(paths.join(sjlj_src, "plain_helper.c"), [[
int plain_c_helper(int x) {
    return x * 2;
}
]]))
        assert(strategy:write_file(paths.join(sjlj_src, "sjlj_pkg/catcher.titan"), [[
function safe_add(a: integer, b: integer): integer
    local sum = a + b
    do
        if sum < 0 then raise "negative" end
    catch
        return 0
    end
    return sum
end
]]))
        assert(strategy:write_file(paths.join(sjlj_src, "sjlj_pkg/plain.titan"), [[
function double_val(a: integer): integer
    return a * 2
end
]]))
        local c_objs_res = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            TITAN_NODE = info.node.path,
            PREFIX = info.prefix,
            ROCKS_TREE = rocks_tree,
            TITAN_ROOT = rocks_tree,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser", "-q",
            "--output", sjlj_out, "-c", "--incremental", "--print-c-objects",
            "--c-source", paths.join(sjlj_src, "sjlj_helper.c"),
            "--c-source", paths.join(sjlj_src, "plain_helper.c"),
        })
        assert.is_true(c_objs_res.ok, c_objs_res.output)
        local sjlj_c_obj, plain_c_obj = c_objs_res.output:match("^([^\r\n]+)\r?\n([^\r\n]+)")
        assert.is_string(sjlj_c_obj)
        assert.is_string(plain_c_obj)

        local pub_lib_res = run_with_env(strategy, {
            PATH = sdk_env.PATH,
            TITAN_NODE = info.node.path,
            PREFIX = info.prefix,
            ROCKS_TREE = rocks_tree,
            TITAN_ROOT = rocks_tree,
            TITAN_PROBE_CACHE_DISABLE = "1",
        }, {
            info.prefix .. "/bin/titanc", "--target", "browser", "-q",
            "--tree", sjlj_src, "--output", sjlj_out, "--incremental",
            "--c-source", paths.join(sjlj_src, "sjlj_helper.c"),
            "--c-source", paths.join(sjlj_src, "plain_helper.c"),
            "sjlj_pkg.catcher", "sjlj_pkg.plain",
        })
        assert.is_true(pub_lib_res.ok, pub_lib_res.output)

        local catcher_obj = assert(staticmetadata.classify_object(
            assert(strategy:read_file(paths.join(sjlj_out, "sjlj_pkg/catcher.o"))), "catcher.o", expected_fp))
        local plain_mod_obj = assert(staticmetadata.classify_object(
            assert(strategy:read_file(paths.join(sjlj_out, "sjlj_pkg/plain.o"))), "plain.o", expected_fp))
        local sjlj_helper_obj = assert(staticmetadata.classify_object(
            assert(strategy:read_file(sjlj_c_obj)), "sjlj_helper.o", expected_fp))
        local plain_helper_obj = assert(staticmetadata.classify_object(
            assert(strategy:read_file(plain_c_obj)), "plain_helper.o", expected_fp))

        assert.equal(fixtures.features, catcher_obj.fingerprint.features)
        assert.equal(fixtures.features, plain_mod_obj.fingerprint.features)
        assert.equal(fixtures.features, sjlj_helper_obj.fingerprint.features)
        assert.equal(fixtures.features, plain_helper_obj.fingerprint.features)

        local sjlj_archive_path = paths.join(sjlj_out, "sjlj_pkg.a")
        local scanned_untargeted = assert(staticmetadata.scan_archive(sjlj_archive_path))
        local scanned_targeted = assert(staticmetadata.scan_archive(sjlj_archive_path, {
            expected_abi = version.TITAN_ABI_VERSION,
            target = expected_fp,
        }))
        assert(driver.validate_browser_provider(scanned_targeted))
        assert.same({ "sjlj_pkg.catcher", "sjlj_pkg.plain" }, scanned_untargeted.key_order)
        assert.equal(4, #scanned_targeted.members)

        -- 4. Native compiler-SDK installation (used by luarocks make) succeeds without emsdk on PATH or EMSDK.
        local native_tree = paths.join(root, "native-compiler-sdk")
        local clean_path = {}
        for entry in (os.getenv("PATH") or ""):gmatch("[^:]+") do
            if not entry:find("emsdk", 1, true) and not entry:find("emscripten", 1, true) then
                clean_path[#clean_path + 1] = entry
            end
        end
        local native_res = run_with_env(strategy, {
            PATH = table.concat(clean_path, ":"),
            EMSDK = "",
        }, {
            "make", "--no-print-directory", "install-compiler-sdk",
            "PREFIX=" .. info.prefix,
            "ROCKS_TREE=" .. native_tree,
            "TITAN_BUILD_PROFILE=validation",
        })
        assert.is_true(native_res.ok, native_res.output)
        assert.equal("file", strategy:stat(paths.join(native_tree, "bin/titanc")).kind)
        assert.equal("file", strategy:stat(paths.join(native_tree, "include/titan.h")).kind)

        local native_probe_c = paths.join(root, "native_stack_probe.c")
        local native_probe_exe = paths.join(root, "native_stack_probe")
        assert(strategy:write_file(native_probe_c, [[
#include "lua.h"
#include "titan.h"
#include "minicoro.h"
static void entry(mco_coro *co) { (void)co; }
int main(void) {
    if (TITAN_COROUTINE_STACK_SIZE != 2 * 1024 * 1024) return 2;
    mco_desc desc = mco_desc_init(entry, TITAN_COROUTINE_STACK_SIZE);
    if (desc.stack_size != 2 * 1024 * 1024) return 3;
    mco_coro *co = NULL;
    if (mco_create(&co, &desc) != MCO_SUCCESS || co == NULL) return 4;
    if (co->stack_size < 2 * 1024 * 1024) return 5;
    mco_destroy(co);
    return 0;
}
]]))
        local cc_res = run_with_env(strategy, {
            PATH = table.concat(clean_path, ":"),
            EMSDK = "",
        }, {
            os.getenv("CC") or "cc", "--std=c99",
            "-I" .. paths.join(native_tree, "src/lua-5.5.1"),
            "-I" .. paths.join(native_tree, "include"),
            native_probe_c,
            paths.join(native_tree, "lib/titan/" .. version.TITAN_LIBRARY_VERSION .. "/libtitan.a"),
            paths.join(native_tree, "lib/liblua.a"),
            paths.join(native_tree, "lib/libbacktrace.a"),
            "-lm", "-o", native_probe_exe,
        })
        assert.is_true(cc_res.ok, cc_res.output)
        local probe_run = strategy:run({ native_probe_exe }, { stderr_to_stdout = true })
        assert.is_true(probe_run.ok, probe_run.output)
    end)
end)

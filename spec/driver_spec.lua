local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local titan = require "titan"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("compiler installation discovery", function()
    it("uses the first literal Lua 5.5 C-module prefix", function()
        local cpath = table.concat({
            "/first prefix/lib/titan/0.22/?.so",
            "/wrong/lib/lua/5.4/?.so",
            "/also-wrong/lib/lua/5.5/?.dylib",
            "/first prefix/lib/lua/5.5/?.so",
            "/second/lib/lua/5.5/?.so",
        }, ";")
        assert.equal("/first prefix",
            driver.root_from_package_cpath(cpath))
    end)

    it("rejects suffix lookalikes and handles the filesystem root", function()
        assert.is_nil(driver.root_from_package_cpath(table.concat({
            "/prefix/lib/lua/5.5/?x.so",
            "/prefix/lib/lua/5.5/?.so.debug",
            "/prefix/lib/lua/5.5/sub/?.so",
        }, ";")))
        assert.equal("/", driver.root_from_package_cpath(
            "/lib/lua/5.5/?.so;/later/lib/lua/5.5/?.so"))
        assert.is_nil(driver.root_from_package_cpath(nil))
    end)

    it("gives the internal installation override precedence", function()
        assert.equal("/post-install/tree", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", "/post-install/tree/"))
        assert.equal("/lua/prefix", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", ""))
        assert.equal(lfs.currentdir() .. "/normalized",
            driver.resolve_installation_root(
                nil, "./discarded/../normalized//"))
    end)

    it("preserves ordinary root spelling but resolves symlink parent traversal",
       function()
        local workspace = os.tmpname()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local physical = workspace .. "/physical"
        local nested = physical .. "/nested"
        assert(lfs.mkdir(physical))
        assert(lfs.mkdir(nested))
        local alias = workspace .. "/alias"
        local command = table.concat({
            "ln", "-s",
            assert(driver.shell_quote(nested)),
            assert(driver.shell_quote(alias)),
        }, " ")
        assert(os.execute(command))

        assert.equal(alias, driver.resolve_installation_root(nil, alias))

        local previous = lfs.currentdir()
        assert(lfs.chdir(physical))
        local expected_parent = lfs.currentdir()
        assert(lfs.chdir(previous))
        assert.equal(expected_parent,
            driver.resolve_installation_root(nil, alias .. "/.."))

        assert(os.remove(alias))
        remove_tree(workspace)
    end)

    it("derives all installed compiler paths from one root", function()
        local paths = assert(driver.installed_paths("/opt/titan/"))
        assert.same({
            root = "/opt/titan",
            lua_source = "/opt/titan/src/lua-5.5.1",
            include = "/opt/titan/include",
            lib = "/opt/titan/lib",
            libtitan = "/opt/titan/lib/libtitan.a",
            libbacktrace = "/opt/titan/lib/libbacktrace.a",
            liblua = "/opt/titan/lib/liblua.a",
            titan_bin = "/opt/titan/lib/titan/0.22",
            lua_cpath = "/opt/titan/lib/titan/0.22/?.so",
        }, paths)

        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-ldl", "-lm",
        }, driver.installed_link_inputs(paths, false))
        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-lm",
        }, driver.installed_link_inputs(paths, true))
    end)

    it("identifies a checkout from driver provenance, not the working directory",
       function()
        local checkout = lfs.currentdir()
        assert.is_true(driver.source_checkout_from_driver_source(
            "@" .. checkout .. "/titan-compiler/driver.lua", "/tmp"))
        assert.is_true(driver.source_checkout_from_driver_source(
            "@./titan-compiler/driver.lua", checkout))
        assert.is_false(driver.source_checkout_from_driver_source(
            "@/opt/titan/share/lua/5.5/titan-compiler/driver.lua",
            checkout))
    end)

    it("requires exactly the three runtime archive members", function()
        assert.is_true(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF SORTED\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF_64\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "__.SYMDEF\ntitan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan_coro.o\ntitan.o\ntitan_uv.o\n"))
    end)

    it("links source builds through the complete runtime archive", function()
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.1/src/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("lua-5.5.1/src"))
    end)

    it("shares the exact generated-object prefix with profiles and probes",
    function()
        local descriptor = assert(driver.toolchain_descriptor())
        local reconstructed = {}
        for _, argument in ipairs(descriptor.compiler_argv) do
            reconstructed[#reconstructed + 1] = argument
        end
        for _, argument in ipairs(descriptor.compile_flags) do
            reconstructed[#reconstructed + 1] = argument
        end
        for _, directory in ipairs(descriptor.include_dirs) do
            reconstructed[#reconstructed + 1] = "-I"
            reconstructed[#reconstructed + 1] = directory
        end

        assert.same(assert(driver.generated_compile_prefix()),
            reconstructed)
        assert.same(driver.foreign_include_dirs(),
            descriptor.include_dirs)
        if not driver.INSTALLED then
            assert.same({
                driver.TITAN_RUNTIME_PATH,
                driver.LUA_SOURCE_PATH,
                driver.LIBBACKTRACE_PATH,
            }, descriptor.include_dirs)
        end
    end)

    it("rescans selected ELF payload after the Titan runtime", function()
        assert.same({
            "-Wl,--start-group",
            "/providers/one.a", "/providers/two.a",
            "-Wl,--end-group",
            "/payload/first.o", "/payload/second.a",
            "-Wl,--start-group",
            "/sdk/libtitan.a",
            "/providers/one.a", "/providers/two.a",
            "-Wl,--end-group",
            "/sdk/libbacktrace.a", "/sdk/liblua.a", "-ldl", "-lm",
        }, driver.standalone_native_link_inputs(
            { "/providers/one.a", "/providers/two.a" },
            { "/payload/first.o", "/payload/second.a" },
            {
                "/sdk/libtitan.a",
                "/sdk/libbacktrace.a",
                "/sdk/liblua.a",
                "-ldl", "-lm",
            },
            false))
    end)

    it("retains continual Darwin standalone archive order", function()
        assert.same({
            "/providers/one.a",
            "/payload/first.o", "/payload/second.a",
            "/sdk/libtitan.a", "/sdk/libbacktrace.a",
            "/sdk/liblua.a", "-lm",
        }, driver.standalone_native_link_inputs(
            { "/providers/one.a" },
            { "/payload/first.o", "/payload/second.a" },
            {
                "/sdk/libtitan.a",
                "/sdk/libbacktrace.a",
                "/sdk/liblua.a",
                "-lm",
            },
            true))
    end)
end)

describe("compiled-container path contracts", function()
    it("deduplicates roots and derives a component-wise provider", function()
        local provider, roots = driver.common_module_provider({
            "foo.bar.left", "foo.bar.left", "foo.bar.right",
        })
        assert.equal("foo.bar", provider)
        assert.same({ "foo.bar.left", "foo.bar.right" }, roots)

        assert.equal("foo", driver.common_module_provider({
            "foo", "foo.bar",
        }))
        local none, _, left, right = driver.common_module_provider({
            "foo.bar", "foobar.baz",
        })
        assert.is_nil(none)
        assert.equal("foo.bar", left)
        assert.equal("foobar.baz", right)
    end)

    it("derives one shallow-to-exact candidate per component", function()
        local cases = {
            { "a", { "a.so" } },
            { "a.b", { "a.so", "a/b.so" } },
            { "a.b.c", { "a.so", "a/b.so", "a/b/c.so" } },
            {
                "a.b.c.d",
                { "a.so", "a/b.so", "a/b/c.so", "a/b/c/d.so" },
            },
        }
        for _, case in ipairs(cases) do
            assert.same(case[2], driver.module_binary_candidates(case[1]))
        end
        assert.same({ "a.a", "a/b.a", "a/b/c.a" },
            driver.module_compiled_candidates("a.b.c", ".a"))
        assert.same({}, driver.module_binary_candidates("a..b"))
        assert.same({},
            driver.module_compiled_candidates("a..b", ".a"))
    end)

    it("expands explicit double separators with the runtime default", function()
        assert.equal("R1;D1;D2;R2",
            driver.expand_titan_bin_path("R1;;R2", "D1;D2"))
        assert.same({ "R1", "D1", "D2", "R2" },
            driver.titan_bin_path_entries("R1;;R2", "D1;D2"))
        assert.same({ "D1", "D2" },
            driver.titan_bin_path_entries(nil, "D1;D2"))
    end)

    it("preserves literal percent signs while inserting defaults", function()
        local explicit = "/tmp/100%/first;;/tmp/50%/last"
        local defaults = "/tmp/default%root;/tmp/other%root"
        assert.equal(table.concat({
            "/tmp/100%/first",
            "/tmp/default%root",
            "/tmp/other%root",
            "/tmp/50%/last",
        }, ";"), driver.expand_titan_bin_path(explicit, defaults))
        assert.same({
            "/tmp/100%/first",
            "/tmp/default%root",
            "/tmp/other%root",
            "/tmp/50%/last",
        }, driver.titan_bin_path_entries(explicit, defaults))
    end)

    it("stages an atomic library under its final basename", function()
        local workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        local public = workspace .. "/nested/provider.so"
        local staged, directory = driver.staged_library_output(public)
        assert.truthy(staged, directory)
        assert.equal("provider.so", staged:match("([^/]+)$"))
        assert.equal(workspace .. "/nested",
            assert(directory:match("^(.*)/[^/]+$")))
        assert.equal(directory .. "/provider.so", staged)
        remove_tree(workspace)
    end)
end)

describe("loader resolver ownership", function()
    it("closes the titanc resolver when an unexpected error unwinds the chunk",
    function()
        local close_calls = 0
        local fake_driver = {
            deduplicate_module_names = function(modules) return modules end,
            new_resolver_context = function() return {} end,
            configure_foreign_c = function() end,
            defaultloader = function()
                error("injected titanc loader failure")
            end,
            close_resolver_context = function(context)
                assert.is_table(context)
                close_calls = close_calls + 1
                return true
            end,
        }
        local argument_parser = {}
        local chain = { args = function(self) return self end }
        function argument_parser:argument() return chain end
        function argument_parser:flag() return chain end
        function argument_parser:option() return chain end
        function argument_parser:parse()
            return {
                module = { "exceptional" },
                extra_object = {},
            }
        end
        local fake_argparse = setmetatable({}, {
            __call = function() return argument_parser end,
        })
        local modules = {
            argparse = fake_argparse,
            ["titan-compiler.checker"] = {},
            ["titan-compiler.coder"] = {},
            ["titan-compiler.parser"] = {},
            ["titan-compiler.driver"] = fake_driver,
            ["titan-compiler.util"] = {},
        }
        local environment = setmetatable({
            arg = {},
            require = function(name)
                return assert(modules[name], "unexpected module " .. name)
            end,
        }, { __index = _G })
        local chunk = assert(loadfile("titanc", "t", environment))
        local ok, err = pcall(chunk)
        assert.is_false(ok)
        assert.matches("injected titanc loader failure", tostring(err),
            1, true)
        assert.equal(1, close_calls)
    end)

    it("closes internally owned default and table resolvers exactly once",
    function()
        local original_close = driver.close_resolver_context
        local close_calls = 0
        driver.close_resolver_context = function(context)
            assert.is_table(context)
            close_calls = close_calls + 1
            return true
        end

        local ran, failure = pcall(function()
            local default = driver.defaultloader({})
            local first, second, third =
                driver.with_loader(default, function(loader)
                    assert.is_function(loader)
                    return "done", nil, 3
                end)
            assert.equal("done", first)
            assert.is_nil(second)
            assert.equal(3, third)
            assert.equal(1, close_calls)
            assert.is_true(driver.close_loader(default))
            assert.equal(1, close_calls)

            local in_memory = driver.tableloader({}, {}, {})
            local body_ok, body_error = pcall(
                driver.with_loader, in_memory, function()
                    error("injected loader body failure")
                end)
            assert.is_false(body_ok)
            assert.matches("injected loader body failure",
                tostring(body_error), 1, true)
            assert.equal(2, close_calls)
            assert.is_true(driver.close_tableloader(in_memory))
            assert.equal(2, close_calls)

            local borrowed_context = driver.new_resolver_context()
            local borrowed = driver.defaultloader({}, {
                context = borrowed_context,
            })
            assert.is_true(driver.close_loader(borrowed))
            assert.equal(2, close_calls)
            assert.is_true(original_close(borrowed_context))
        end)
        driver.close_resolver_context = original_close
        assert.truthy(ran, failure)
    end)

    it("reports an owned resolver close failure after a successful body",
    function()
        local original_close = driver.close_resolver_context
        driver.close_resolver_context = function()
            return nil, "injected resolver close failure"
        end
        local loader = driver.defaultloader({})
        local ok, err = pcall(
            driver.with_loader, loader, function() return true end)
        driver.close_resolver_context = original_close

        assert.is_false(ok)
        assert.matches("failed to close loader resolver context", err)
        assert.matches("injected resolver close failure", err)
        assert.is_true(driver.close_loader(loader))
    end)
end)

describe("compiler module loader", function()
    local root
    local source
    local binary
    local previous

    local function cache_static_provider(context, filename, module_types)
        write_file(filename, "mock static provider\n")
        local provider = {
            archive = filename,
            entries = {},
            key_order = {},
        }
        for name, modtype in pairs(module_types) do
            provider.entries[name] = {
                type = modtype,
                types = types.serialize(modtype),
                origin = filename .. ":" .. name,
            }
            provider.key_order[#provider.key_order + 1] = name
        end
        table.sort(provider.key_order, util.bytewise_less)
        context.provider_cache[filename] = provider
        return provider
    end

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        source = root .. "/source"
        binary = root .. "/binary"
        assert(lfs.mkdir(source))
        assert(lfs.mkdir(binary))
        assert(lfs.mkdir(source .. "/titan"))
        assert(lfs.mkdir(binary .. "/titan"))

        previous = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            imported = driver.imported,
            registry = types.registry,
            loadlib = titan._loadlib,
        }
        driver.TITAN_SOURCE_PATH = source
        driver.TITAN_BIN_PATH = binary
        driver.imported = {}
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.imported = previous.imported
        types.registry = previous.registry
        titan._loadlib = previous.loadlib
        remove_tree(root)
    end)

    it("uses binaries for dependencies and source for explicit roots", function()
        assert(lfs.mkdir(source .. "/titan/timer"))
        write_file(source .. "/titan/timer/timer.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(binary .. "/titan/timer.so", "mock interface\n")

        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan/timer.so", filename)
            symbols[#symbols + 1] = symbol
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "titan_timer_abi", "titan_timer_types" }, symbols)
        assert.is_nil(driver.imported["titan.timer"].ast)

        -- A later explicit build request replaces a cached binary interface
        -- with the source root instead of silently treating compilation as a
        -- no-op.
        local deps = {}
        ok, modtype, errors = driver.defaultloader(deps, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.timer"].ast)
        assert.equal(true, deps["titan.timer"])
        assert.equal(source .. "/titan/timer/timer.titan",
            driver.imported["titan.timer"].filename)
        assert.equal("titan/timer__main",
            driver.imported["titan.timer"].program_output)
    end)

    it("keeps root precedence ahead of candidate shallowness", function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(first .. "/a"))
        assert(lfs.mkdir(first .. "/a/b"))
        write_file(first .. "/a/b/c.so", "earlier exact\n")
        write_file(second .. "/a.so", "later shallow\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        titan._loadlib = function(filename, symbol)
            assert.equal(first .. "/a/b/c.so", filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b/c.so", modtype.file)
        assert.equal(first .. "/a/b/c.so",
            driver.imported["a.b.c"].filename)
    end)

    it("applies the selected format preference globally across path roots",
       function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        local archive = first .. "/choice.a"
        local dynamic = second .. "/choice.so"
        write_file(dynamic, "later dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local static_context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(static_context, archive, {
            choice = types.Module("choice", {}),
        })
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic, filename)
            if symbol == "choice_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "choice_types" then
                return function() return "Module('choice',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local dynamic_context = driver.new_resolver_context()
        -- Seed the otherwise independent context too: the existing archive
        -- must be inspectable if the dynamic format pass fails.
        dynamic_context.provider_cache[archive] =
            static_context.provider_cache[archive]
        local ok, modtype, errors = driver.defaultloader({}, {
            context = dynamic_context,
        })("choice")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported.choice.kind)
        assert.equal("choice.so", modtype.file)
        assert.equal(dynamic, driver.imported.choice.filename)

        driver.imported = {}
        ok, modtype, errors = driver.defaultloader({}, {
            context = static_context,
        })("choice")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported.choice.kind)
        assert.equal("choice.so", modtype.file)
        assert.equal(archive, driver.imported.choice.static_archive)
    end)

    it("keeps root precedence ahead of archive candidate shallowness",
       function()
        local first = root .. "/first-static"
        local second = root .. "/second-static"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(first .. "/a"))
        assert(lfs.mkdir(first .. "/a/b"))
        local earlier_exact = first .. "/a/b/c.a"
        local later_shallow = second .. "/a.a"
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, earlier_exact, {
            ["a.b.c"] = types.Module("a.b.c", {}),
        })
        cache_static_provider(context, later_shallow, {
            ["a.b.c"] = types.Module("a.b.c", {}),
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b/c.so", modtype.file)
        assert.equal(earlier_exact,
            driver.imported["a.b.c"].static_archive)
        assert.equal("a/b/c.a", driver.imported["a.b.c"].relative)
    end)

    it("tracks occupied archive candidates independently and continues deeper",
       function()
        local first = root .. "/occupied-static"
        local second = root .. "/later-static"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(second .. "/a"))
        local earlier_nonclaim = first .. "/a.a"
        local shadowed_claim = second .. "/a.a"
        local unshadowed_claim = second .. "/a/b.a"
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, earlier_nonclaim, {})
        cache_static_provider(context, shadowed_claim, {
            ["a.b"] = types.Module("a.b", {}),
        })
        cache_static_provider(context, unshadowed_claim, {
            ["a.b"] = types.Module("a.b", {}),
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("a.b")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b.so", modtype.file)
        assert.equal(unshadowed_claim,
            driver.imported["a.b"].static_archive)
        assert.equal("a/b.a", driver.imported["a.b"].relative)
    end)

    it("does not let an occupied DSO pathname shadow an archive pathname",
       function()
        local first = root .. "/dynamic-occupancy"
        local second = root .. "/static-occupancy"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        local dynamic_nonclaim = first .. "/mixed.so"
        local archive = second .. "/mixed.a"
        write_file(dynamic_nonclaim, "unrelated dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context = driver.new_resolver_context()
        cache_static_provider(context, archive, {
            ["mixed.child"] = types.Module("mixed.child", {}),
        })
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic_nonclaim, filename)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("mixed.child")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported["mixed.child"].kind)
        assert.equal(archive,
            driver.imported["mixed.child"].static_archive)
        assert.equal("mixed/child.so", modtype.file)
    end)

    it("treats an exact archive nonclaim as terminal", function()
        local archive = binary .. "/empty.a"
        local dynamic = binary .. "/empty.so"
        write_file(dynamic, "must not be inspected\n")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, archive, {})
        titan._loadlib = function()
            error("an exact static nonclaim must not fall through")
        end

        local ok, message = driver.defaultloader({}, {
            context = context,
        })("empty")
        assert.falsy(ok)
        assert.match("exact static provider '" .. archive ..
            "' contains no metadata for module 'empty'", message, 1, true)
        assert.is_nil(driver.imported.empty)
    end)

    it("rejects a claimed malformed Interface in an archive before fallback",
       function()
        local archive = binary .. "/archive_bad.a"
        local dynamic = binary .. "/archive_bad.so"
        write_file(archive, "selected static provider\n")
        write_file(dynamic, "must not be inspected\n")
        local original_scan = staticmetadata.scan_archive
        local dynamic_probed = false

        local ran, failure = pcall(function()
            staticmetadata.scan_archive = function(filename, options)
                assert.equal(archive, filename)
                local serialized = [[
                    Module("archive_bad", {}, {
                        I = {
                            _tag = "Type.Interface",
                            name = "archive_bad.I",
                            methods = {},
                        },
                    })
                ]]
                local decoded, message = options.validate_types(
                    "archive_bad", serialized,
                    archive .. ":archive_bad")
                assert.is_nil(decoded)
                return nil, message
            end
            titan._loadlib = function()
                dynamic_probed = true
                error("a dynamic provider must not hide malformed archive metadata")
            end

            local ok, message = driver.defaultloader({}, {
                context =
                    driver.new_resolver_context({ prefer_static = true }),
            })("archive_bad")
            assert.falsy(ok)
            assert.match(archive, message, 1, true)
            assert.match("archive_bad", message, 1, true)
            assert.match("interface method list is empty", message, 1, true)
            assert.is_false(dynamic_probed)
            assert.is_nil(driver.imported.archive_bad)
        end)
        staticmetadata.scan_archive = original_scan
        assert.truthy(ran, failure)
    end)

    it("rejects an occupied nonregular static candidate without opening it",
       function()
        local candidate = binary .. "/blocked.a"
        assert(lfs.mkdir(candidate))
        driver.TITAN_BIN_PATH = binary

        local ok, message = driver.defaultloader({}, {
            context =
                driver.new_resolver_context({ prefer_static = true }),
        })("blocked")
        assert.falsy(ok)
        assert.match("static provider candidate '" .. candidate ..
            "' for module 'blocked' is not a readable regular file",
            message, 1, true)
    end)

    it("selects one archive key without importing carried siblings", function()
        local archive = binary .. "/bundle.a"
        local left = types.Module("bundle.left", {})
        local right = types.Module("bundle.right", {})
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, archive, {
            ["bundle.left"] = left,
            ["bundle.right"] = right,
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("bundle.left")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported["bundle.left"].kind)
        assert.is_nil(driver.imported["bundle.right"])
        assert.equal("bundle/left.so", modtype.file)
        assert.is_nil(types.serialize(modtype):find(archive, 1, true))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.is_nil(driver.imported["bundle.right"])
        assert.equal("direct",
            context.native_bindings["bundle.right"])
    end)

    it("shadows an occupied relative candidate in later roots", function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(second .. "/a"))
        write_file(first .. "/a.so", "earlier nonclaim\n")
        write_file(second .. "/a.so", "later claim must be shadowed\n")
        write_file(second .. "/a/b.so", "later unshadowed claim\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local inspected = {}
        titan._loadlib = function(filename, symbol)
            inspected[filename] = true
            if filename == first .. "/a.so" then
                return nil, "undefined symbol: " .. symbol, "init"
            end
            assert.equal(second .. "/a/b.so", filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b.so", modtype.file)
        assert.equal(second .. "/a/b.so",
            driver.imported["a.b.c"].filename)
        assert.is_nil(inspected[second .. "/a.so"])
    end)

    it("treats half metadata as a terminal container claim", function()
        write_file(binary .. "/titan.so", "partial shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_VER end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_types", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats types-only metadata as a terminal container claim", function()
        write_file(binary .. "/titan.so", "partial shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_abi", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("rejects a wrong ABI before executing types metadata", function()
        write_file(binary .. "/titan.so", "stale shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local types_executed = false
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a stale claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return "stale" end
            elseif symbol == "titan_timer_types" then
                return function()
                    types_executed = true
                    return "Module('titan.timer',{})"
                end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("ABI mismatch", message, 1, true)
        assert.match("but found stale", message, 1, true)
        assert.is_false(types_executed)
        assert.is_false(exact_probed)
    end)

    it("rejects invalid metadata results without falling through", function()
        write_file(binary .. "/meta.so", "invalid metadata claims\n")

        local cases = {
            {
                name = "meta.malformed",
                abi = function() return driver.TITAN_VER end,
                metadata = function() return "@" end,
                expected = "unexpected symbol near '@'",
            },
            {
                name = "meta.call_error",
                abi = function() return driver.TITAN_VER end,
                metadata = function() error("types metadata exploded") end,
                expected = "types metadata exploded",
            },
            {
                name = "meta.arity",
                abi = function() return driver.TITAN_VER, "extra" end,
                metadata = function()
                    error("types metadata must not execute")
                end,
                expected = "compiled module ABI marker 'meta_arity_abi' " ..
                    "must return exactly one string",
            },
            {
                name = "meta.non_string",
                abi = function() return driver.TITAN_VER end,
                metadata = function() return 42 end,
                expected = "compiled module type metadata " ..
                    "'meta_non_string_types' must return exactly one string",
            },
            {
                name = "meta.noncanonical",
                abi = function() return driver.TITAN_VER end,
                metadata = function()
                    return [[{ _tag = "Type.Module",
                        name = "meta.noncanonical", members = {} }]]
                end,
                expected = "did not construct a canonical Type.Module",
            },
            {
                name = "meta.member_schema",
                abi = function() return driver.TITAN_VER end,
                metadata = function()
                    return [[Module("meta.member_schema", {
                        ModuleMember("meta.member_schema", "bad",
                            { _tag = "Type.Unknown" }, false)
                    })]]
                end,
                expected = "Type.Unknown is not valid in a " ..
                    "value-facing type graph",
            },
            {
                name = "meta.interface_schema",
                abi = function() return driver.TITAN_VER end,
                metadata = function()
                    return [[Module("meta.interface_schema", {}, {
                        I = {
                            _tag = "Type.Interface",
                            name = "meta.interface_schema.I",
                            methods = {},
                        },
                    })]]
                end,
                expected = "interface method list is empty",
                retains_claim = true,
            },
        }

        for _, case in ipairs(cases) do
            titan._loadlib = function(filename, symbol)
                assert.equal(binary .. "/meta.so", filename)
                if symbol == driver.mangle_module_name(case.name) .. "_abi" then
                    return case.abi
                elseif symbol == driver.mangle_module_name(case.name) ..
                                  "_types" then
                    return case.metadata
                end
                error("unexpected metadata symbol " .. symbol)
            end

            local ok, message = driver.defaultloader({})(case.name)
            assert.falsy(ok)
            assert.match(case.expected, message, 1, true)
            if case.retains_claim then
                assert.match(binary .. "/meta.so", message, 1, true)
                assert.match(case.name, message, 1, true)
            end
            assert.is_nil(driver.imported[case.name])
        end
    end)

    it("rejects metadata for a different logical module", function()
        write_file(binary .. "/titan.so", "mismatched shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide mismatched metadata")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.other',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("returned type metadata for 'titan.other'", message,
            1, true)
        assert.match("while loading module 'titan.timer'", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats a candidate open failure as a terminal error", function()
        write_file(binary .. "/titan.so", "broken shallow image\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan.so", filename)
            table.insert(symbols, symbol)
            return nil, "broken image", "open"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("cannot inspect compiled module 'titan.timer'", message,
            1, true)
        assert.match("broken image", message, 1, true)
        assert.same({ "titan_timer_abi" }, symbols)
    end)

    it("uses the first valid claim without probing a duplicate", function()
        assert(lfs.mkdir(binary .. "/dup"))
        write_file(binary .. "/dup.so", "shallow claim\n")
        write_file(binary .. "/dup/item.so", "duplicate exact claim\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/dup.so", filename)
            table.insert(symbols, symbol)
            if symbol == "dup_item_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "dup_item_types" then
                return function() return "Module('dup.item',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, modtype, errors = driver.defaultloader({})("dup.item")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("dup.so", modtype.file)
        assert.equal(binary .. "/dup.so",
            driver.imported["dup.item"].filename)
        assert.same({ "dup_item_abi", "dup_item_types" }, symbols)
    end)

    it("caches two logical interfaces from one physical container separately",
       function()
        write_file(binary .. "/bundle.so", "two logical interfaces\n")
        local functions = {
            bundle_left_abi = function() return driver.TITAN_VER end,
            bundle_left_types = function()
                return "Module('bundle.left',{})"
            end,
            bundle_right_abi = function() return driver.TITAN_VER end,
            bundle_right_types = function()
                return "Module('bundle.right',{})"
            end,
        }
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/bundle.so", filename)
            table.insert(symbols, symbol)
            return assert(functions[symbol], "unexpected metadata symbol")
        end

        local loader = driver.defaultloader({})
        local left_ok, left, left_errors = loader("bundle.left")
        local right_ok, right, right_errors = loader("bundle.right")
        assert.truthy(left_ok)
        assert.truthy(right_ok)
        assert.equal(0, #left_errors)
        assert.equal(0, #right_errors)
        assert.not_equal(left, right)
        assert.not_equal(driver.imported["bundle.left"],
            driver.imported["bundle.right"])
        assert.equal("bundle.so", left.file)
        assert.equal("bundle.so", right.file)
        assert.equal(binary .. "/bundle.so",
            driver.imported["bundle.left"].filename)
        assert.equal(binary .. "/bundle.so",
            driver.imported["bundle.right"].filename)
        assert.same({
            "bundle_left_abi", "bundle_left_types",
            "bundle_right_abi", "bundle_right_types",
        }, symbols)
        local call_count = #symbols
        local cached_ok, cached_left, cached_errors = loader("bundle.left")
        assert.truthy(cached_ok)
        assert.equal(left, cached_left)
        assert.equal(0, #cached_errors)
        assert.equal(call_count, #symbols)
    end)

    it("falls back to source after clean ancestor nonclaims", function()
        write_file(binary .. "/titan.so", "unrelated extension\n")
        write_file(source .. "/titan/fallback.titan", [[
            function marker(): integer return 17 end
        ]])
        titan._loadlib = function(_, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("titan.fallback")
        assert.truthy(ok)
        assert.equal("titan.fallback", modtype.name)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.fallback"].ast)
    end)

    it("assembles a folder module in deterministic source order", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan", [[
            local decoy: integer = 99
        ]])
        write_file(folder .. "/sample.titan", [[
            local from_main: integer = 1
            do
                from_main = from_main + from_zero()
            end
        ]])
        -- Deliberately create contributors in an order unrelated to the
        -- required raw-byte basename order.
        write_file(folder .. "/z.titan",
            "local from_z: integer = 1\n")
        write_file(folder .. "/a.titan",
            "local from_a: integer = 1\n")
        -- Use a digit rather than a case-only filename distinction: the
        -- default macOS filesystem aliases A.titan and a.titan. The pure
        -- comparator spec separately covers uppercase/lowercase byte order.
        write_file(folder .. "/0.titan", [[
            function from_zero(): integer
                do
                    return 1
                end
            end
        ]])
        write_file(folder .. "/aa.titan",
            "local from_aa: integer = 1\n")
        write_file(folder .. "/\195\169.titan",
            "local from_utf8: integer = 1\n")
        write_file(folder .. "/ignored.lua", "return {}\n")
        assert(lfs.mkdir(folder .. "/nested.titan"))

        local ok, modtype, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")

        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        assert.equal(folder .. "/sample.titan", imported.filename)
        assert.equal("titan/sample__main", imported.program_output)
        assert.equal(7, #imported.ast)
        assert.same({
            folder .. "/sample.titan",
            folder .. "/0.titan",
            folder .. "/a.titan",
            folder .. "/aa.titan",
            folder .. "/z.titan",
            folder .. "/\195\169.titan",
            folder .. "/sample.titan",
        }, {
            imported.ast[1].loc.filename,
            imported.ast[2].loc.filename,
            imported.ast[3].loc.filename,
            imported.ast[4].loc.filename,
            imported.ast[5].loc.filename,
            imported.ast[6].loc.filename,
            imported.ast[7].loc.filename,
        })
        assert.equal("Ast.StatBlock", imported.ast[7]._tag)
    end)

    it("shares an Interface declaration and implementation across constituents",
       function()
        local folder = source .. "/titan/interfaces"
        assert(lfs.mkdir(folder))
        local main = folder .. "/interfaces.titan"
        local part = folder .. "/provider.titan"
        write_file(main, [[
            interface Counter
                function step(delta: integer): integer
            end
        ]])
        write_file(part, [[
            record Box
                n: integer
            end

            function Box:step(delta: integer): integer
                return self.n + delta
            end

            function use(box: Box): integer
                local counter: Counter = box
                return counter:step(2)
            end
        ]])

        local ok, modtype, errors = driver.defaultloader({}, {
            source_roots = { ["titan.interfaces"] = true },
        })("titan.interfaces")
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("Type.Interface",
            modtype.type_members.Counter._tag)
        assert.is_nil(modtype.members.Counter)
        assert.equal("Type.Record",
            modtype.members.Box.type._tag)
        assert.equal("Type.Function",
            modtype.members.use.type._tag)

        local imported = driver.imported["titan.interfaces"]
        assert.equal(main, imported.ast[1].loc.filename)
        assert.equal(part, imported.ast[2].loc.filename)
        assert.equal(part, imported.ast[3].loc.filename)
        assert.equal(part, imported.ast[4].loc.filename)
    end)

    it("attributes a cross-constituent Interface mismatch to the real cast file",
       function()
        local folder = source .. "/titan/interface_mismatch"
        assert(lfs.mkdir(folder))
        local main = folder .. "/interface_mismatch.titan"
        local provider = folder .. "/provider.titan"
        local bridge = folder .. "/bridge.titan"
        write_file(main, [[
            interface Counter
                function step(delta: integer): integer
            end
        ]])
        write_file(provider, [[
            record Box end

            function Box:step(delta: string): integer
                return 0
            end
        ]])
        write_file(bridge, [[
            function use(box: Box): Counter
                return box
            end
        ]])

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = {
                ["titan.interface_mismatch"] = true,
            },
        })("titan.interface_mismatch")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(bridge .. ":2:24: type error:", errors[1], 1, true)
        assert.match(
            "record 'titan%.interface_mismatch%.Box' does not implement " ..
            "interface 'titan%.interface_mismatch%.Counter'",
            errors[1])
        assert.match("method 'step' has incompatible type", errors[1], 1, true)
        assert.match("expected", errors[1], 1, true)
    end)

    it("honors source-root order across flat and folder representations",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        write_file(source .. "/titan/sample.titan",
            "local from_flat: integer = 1\n")
        write_file(later .. "/titan/sample/sample.titan",
            "local from_folder: integer = 1\n")

        driver.TITAN_SOURCE_PATH = source .. ";" .. later
        local loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(source .. "/titan/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample",
            driver.imported["titan.sample"].program_output)

        driver.imported = {}
        types.registry = {}
        driver.TITAN_SOURCE_PATH = later .. ";" .. source
        loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample__main",
            driver.imported["titan.sample"].program_output)
    end)

    it("blocks constituent flat sources but permits a deeper folder module",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")

        local child_loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })
        local ok, message = child_loader("titan.sample.child")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.child' cannot be loaded directly",
            message, 1, true)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.match("folder module 'titan.sample'", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)

        ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.sample"] = true },
        })("titan.sample.sample")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.sample' cannot be loaded directly",
            message, 1, true)

        assert(lfs.mkdir(folder .. "/child"))
        write_file(folder .. "/child/child.titan", [[
            function distinct(): integer
                return 2
            end
        ]])
        ok, _, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #message)
        assert.equal(folder .. "/child/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("does not fall through a blocked constituent in an earlier root",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.falsy(ok)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.not_match(later, message, 1, true)
    end)

    it("allows a later nested flat module when the earlier constituent is absent",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("uses an exact child binary before applying folder-source privacy",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        assert(lfs.mkdir(binary .. "/titan/sample"))
        local child_binary = binary .. "/titan/sample/child.so"
        write_file(child_binary, "mock interface\n")

        titan._loadlib = function(filename, symbol)
            assert.equal(child_binary, filename)
            if symbol == "titan_sample_child_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_sample_child_types" then
                return function()
                    return "Module('titan.sample.child',{})"
                end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.sample.child")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal(child_binary,
            driver.imported["titan.sample.child"].filename)
        assert.is_nil(driver.imported["titan.sample.child"].ast)
    end)

    it("reports folder enumeration failure without falling back", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")

        local real_dir = lfs.dir
        lfs.dir = function(path)
            if path == folder then error("permission denied") end
            return real_dir(path)
        end
        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        lfs.dir = real_dir

        assert.truthy(called)
        assert.falsy(ok)
        assert.match("cannot enumerate folder module 'titan.sample'",
            message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.match("permission denied", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("treats a selected contributor read failure as a hard error",
       function()
        local folder = source .. "/titan/sample"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(part, "local contributor: integer = 2\n")

        local real_get_file_contents = util.get_file_contents
        util.get_file_contents = function(path)
            if path == part then
                return false, part .. ": forced read failure"
            end
            return real_get_file_contents(path)
        end
        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        util.get_file_contents = real_get_file_contents

        assert.truthy(called)
        assert.falsy(ok)
        assert.equal(part .. ": forced read failure", message)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a contributor initializer at its exact source location",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "\ndo\n    local invalid: integer = 1\nend\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a protected contributor initializer by its parser role",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan", [[

do
    defer local cleaned: boolean = true
    raise "expected"
catch
    local caught: value = error
end
]])

        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        assert.truthy(called)
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("moves a protected main initializer after contributor declarations",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan", [[
answer: integer = 0

do
    defer answer = answer + 1
    raise "expected"
catch
    answer = contributor_answer()
end
]])
        write_file(folder .. "/part.titan", [[
local function contributor_answer(): integer
    return 41
end
]])

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local combined = driver.imported["titan.sample"].ast
        assert.equal("Ast.TopLevelFunc", combined[#combined - 1]._tag)
        assert.equal("contributor_answer", combined[#combined - 1].name)
        assert.equal("Ast.StatTry", combined[#combined]._tag)
        assert.is_true(combined[#combined]._module_initializer)
    end)

    it("reports a syntax error from the failing contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/broken.titan", "function broken(\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/broken.titan:2:1: syntax error:",
            message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("reports an exact type-error location from a contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local invalid: integer = \"not an integer\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1: type error:",
            errors[1], 1, true)
        assert.match("declaration of module variable invalid", errors[1],
            1, true)
    end)

    it("tracks contributor imports in one logical dependency closure",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/alpha.titan", [[
            function alpha(): integer return 1 end
        ]])
        write_file(source .. "/titan/beta.titan", [[
            function beta(): integer return 2 end
        ]])
        write_file(folder .. "/sample.titan", [[
            local alpha = import "titan.alpha"
            function from_main(): integer return alpha.alpha() end
        ]])
        write_file(folder .. "/part.titan", [[
            local beta = import "titan.beta"
            function from_part(): integer return beta.beta() end
        ]])

        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, modtype, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        local original_ast = imported.ast
        assert.same({
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, imported.deps)
        assert.same({
            ["titan.sample"] = true,
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, driver.dependency_closure("titan.sample"))
        assert.same(driver.dependency_closure("titan.sample"), static_deps)

        local cached_ok, cached_type, cached_errors = loader("titan.sample")
        assert.truthy(cached_ok)
        assert.equal(modtype, cached_type)
        assert.equal(0, #cached_errors)
        assert.equal(original_ast, driver.imported["titan.sample"].ast)
    end)

    it("keeps folder identity marked across repeated self-imports", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local self_main = import \"titan.sample\"\n")
        write_file(folder .. "/part.titan",
            "\nlocal self_part = import \"titan.sample\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(2, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(folder .. "/sample.titan:1:1", all_errors, 1, true)
        assert.match(folder .. "/part.titan:2:1", all_errors, 1, true)
        assert.match("circular reference to module", all_errors, 1, true)
        assert.is_table(driver.imported["titan.sample"].ast)
        local cache_entries = 0
        for _ in pairs(driver.imported) do
            cache_entries = cache_entries + 1
        end
        assert.equal(1, cache_entries)
    end)

    it("attributes a blocked sibling import to its contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local sibling = import \"titan.sample.part\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1", errors[1], 1, true)
        assert.match("source module 'titan.sample.part' cannot be loaded " ..
            "directly", errors[1], 1, true)
        assert.match(folder .. "/part.titan", errors[1], 1, true)
        assert.is_nil(driver.imported["titan.sample.part"])
    end)

    it("reports both files for cross-file duplicate declarations", function()
        local folder = source .. "/titan/sample"
        local main = folder .. "/sample.titan"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(main, table.concat({
            "record Box end",
            "type Count = integer",
            "interface Stream function read(): string end",
            "local item = 1",
            "",
        }, "\n"))
        write_file(part, table.concat({
            "type Count = string",
            "type Box = integer",
            "interface Stream function read(): string end",
            "local item = 2",
            "",
        }, "\n"))

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(4, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(part .. ":1:1: type error: duplicate type alias for " ..
            "Count, previous one at " .. main .. ":2:1",
            all_errors, 1, true)
        assert.match(part .. ":2:1: type error: type alias 'Box' conflicts " ..
            "with record declared at " .. main .. ":1:1",
            all_errors, 1, true)
        assert.match(part .. ":3:1: type error: duplicate interface 'Stream', " ..
            "previous one at " .. main .. ":3:1",
            all_errors, 1, true)
        assert.match(part .. ":4:1: type error: duplicate declaration for " ..
            "item, previous one at " .. main .. ":4:1",
            all_errors, 1, true)
    end)

    it("rejects malformed module names without crashing", function()
        local malformed = {
            "", ".", "titan.", ".titan", "titan..timer",
            "1titan", "-titan", "titan.$line", "titan timer",
            "titan/timer",
        }
        local source_roots = {}
        for _, name in ipairs(malformed) do source_roots[name] = true end
        local loader = driver.defaultloader({}, {
            source_roots = source_roots,
        })

        for _, name in ipairs(malformed) do
            local called, ok, message = pcall(loader, name)
            assert.truthy(called)
            assert.falsy(ok)
            assert.match(
                "invalid logical Titan module name", message, 1, true)
        end

        local called, plans, message = pcall(
            driver.plan_module_shims,
            "provider$line", { "module$line" })
        assert.truthy(called)
        assert.falsy(plans)
        assert.match("invalid library provider name", message, 1, true)
    end)

    it("requires source for an explicit build root", function()
        write_file(binary .. "/titan/timer.so", "existing binary\n")
        titan._loadlib = function()
            error("an explicit source build must not load its existing binary")
        end

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")

        assert.falsy(ok)
        assert.equal("source module 'titan.timer' not found", message)
        assert.is_nil(driver.imported["titan.timer"])
    end)

    it("reports a missing ABI entry from the internal loader", function()
        write_file(binary .. "/extension.so", "mock image\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/extension.so", filename)
            table.insert(symbols, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("extension")
        assert.falsy(ok)
        assert.match("has no compatible Titan ABI marker", message)
        assert.same({ "extension_abi", "extension_types" }, symbols)
    end)

    it("records a cached table-loader import as a dependency", function()
        local modtype = types.Module("cached", {})
        local imported = { cached = { type = modtype } }
        local deps = {}

        local ok, loaded, errors =
            driver.tableloader({}, imported, deps)("cached")

        assert.truthy(ok)
        assert.equal(modtype, loaded)
        assert.equal(0, #errors)
        assert.equal(true, deps.cached)
    end)
end)

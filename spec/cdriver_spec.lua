local lfs = require "lfs"

local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"

local function write_file(filename, contents)
    local fd = assert(io.open(filename, "wb"))
    fd:write(contents)
    fd:close()
end

local function tmp_header(contents)
    local filename = os.tmpname() .. ".h"
    write_file(filename, contents)
    return filename
end

local function tmp_dir()
    local dirname = os.tmpname()
    os.remove(dirname)
    assert(lfs.mkdir(dirname))
    return dirname
end

local function mkdir(parent, name)
    local dirname = parent .. "/" .. name
    assert(lfs.mkdir(dirname))
    return dirname
end

local function remove_tree(files, dirs)
    for _, filename in ipairs(files or {}) do
        os.remove(filename)
    end
    for i = #(dirs or {}), 1, -1 do
        lfs.rmdir(dirs[i])
    end
end

local function assert_process_file(filename, options)
    local ffi_types, err, include, context =
        cdriver.process_file(filename, options)
    assert(ffi_types, err)
    assert.is_nil(err)
    assert.is_table(include)
    return ffi_types, include, context
end

describe("completed C header payload transport", function()
    local files, original_match, matches, payloads, adapter
    before_each(function()
        files, matches, payloads = {}, 0, {}
        cdriver.clear_process_cache()
        local c99 = require "c-parser.c99"
        original_match = c99.match_language_grammar
        c99.match_language_grammar = function(...)
            matches = matches + 1
            return original_match(...)
        end
        adapter = {
            get = function(kind, key) return payloads[kind .. "\0" .. key] end,
            put = function(kind, key, payload)
                payloads[kind .. "\0" .. key] = payload
                return true
            end,
        }
    end)
    after_each(function()
        require("c-parser.c99").match_language_grammar = original_match
        cdriver.clear_process_cache()
        for _, file in ipairs(files) do os.remove(file) end
    end)
    local function header(source)
        local path = tmp_header(source)
        files[#files + 1] = path
        return path
    end

    it("reopens complete graphs without parsing and preserves macro sidecars", function()
        local cpp = require "c-parser.cpp"
        local path = header("typedef struct node node;\nstruct node { node *next; };\n")
        local options = {
            cache_adapter = adapter,
            cppflags = { "-DTITAN_STR(x)=#x", "-DTITAN_VALUE=TITAN_STR(a + b)" },
        }
        local first = assert_process_file(path, options)
        assert.equal(1, matches)
        assert.is_not_nil(next(payloads))
        cdriver.clear_process_cache()
        cpp.clear_probe_cache()
        local restored, include = assert_process_file(path, options)
        assert.equal(1, matches)
        assert.equal(1, cdriver.process_cache_stats().hits)
        assert.equal('"a + b"', cpp.expand_macro("TITAN_VALUE", restored.macro_definitions))
        assert.not_equal(first.node, restored.node)
        assert.matches("titan-cdriver-process-v2:sha256:", include.c_header_graph_key, 1, true)
        restored.node.def[1] = "mutated"
        local clean = assert_process_file(path, options)
        assert.not_equal("mutated", clean.node.def[1])
    end)

    it("invalidates changed header bytes despite preserved mtime", function()
        local path = header("typedef int changed_type;\n")
        local options = { cache_adapter = adapter }
        assert_process_file(path, options)
        local stamp = assert(lfs.attributes(path, "modification"))
        write_file(path, "typedef unsigned changed_type;\n")
        assert(lfs.touch(path, stamp, stamp))
        cdriver.clear_process_cache()
        local restored = assert_process_file(path, options)
        assert.equal(2, matches)
        assert.same({ "unsigned" }, restored.changed_type.def)
    end)

    it("rebuilds corrupt transport payloads and tolerates transport failure", function()
        local path = header("typedef int safe_type;\n")
        local options = { cache_adapter = adapter }
        assert_process_file(path, options)
        for key, payload in pairs(payloads) do payloads[key] = payload:sub(1, -2) end
        cdriver.clear_process_cache()
        assert_process_file(path, options)
        assert.equal(2, matches)
        cdriver.clear_process_cache()
        options.cache_adapter = {
            get = function() error("storage unavailable") end,
            put = function() error("storage unavailable") end,
        }
        assert_process_file(path, options)
        assert.equal(3, matches)
    end)

    it("does not publish through a read-only adapter", function()
        local path = header("typedef int readonly_type;\n")
        assert_process_file(path, { cache_adapter = { get = adapter.get } })
        assert.is_nil(next(payloads))
        assert.equal(1, matches)
    end)

    it("uses adapter checksums for persisted headers and preserves hash cancellation", function()
        local path = header("typedef int hashed_type;\n")
        local hashes = 0
        adapter.sha256_binary = function(bytes)
            hashes = hashes + 1
            return require("titan-compiler.sha256").binary(bytes)
        end
        assert_process_file(path, { cache_adapter = adapter })
        assert.equal(1, hashes)
        cdriver.clear_process_cache()
        assert_process_file(path, { cache_adapter = adapter })
        assert.equal(2, hashes)
        assert.equal(1, matches)
        cdriver.clear_process_cache()
        local cancelled = {}
        adapter.sha256_binary = function() error(cancelled, 0) end
        local ok, err = pcall(cdriver.process_file, path, { cache_adapter = adapter })
        assert.is_false(ok)
        assert.equal(cancelled, err)
        adapter.sha256_binary = function() return "invalid digest" end
        assert_process_file(path, { cache_adapter = adapter })
        assert.equal(2, matches)
        adapter.sha256_binary = false
        local result, invalid = cdriver.process_file(path, { cache_adapter = adapter })
        assert.is_nil(result)
        assert.matches("sha256_binary", invalid, 1, true)
    end)

    it("retains direct symlink identity even when the target bytes are identical", function()
        local path = header("typedef int link_type;\n")
        local link = path .. ".link"
        assert(lfs.link(path, link, true))
        files[#files + 1] = link
        local strategy = compiler_io.new_sync()
        local first = assert(cdriver.header_input_identity("file", link, strategy))
        os.remove(link)
        assert(lfs.link(path, link))
        local second = assert(cdriver.header_input_identity("file", link, strategy))
        assert.not_equal(first, second)
        assert.matches(";lstat=", first, 1, true)
    end)
end)

describe("C FFI cdriver", function()
    describe("top-level include descriptor", function()
        it("treats absolute paths as quoted includes", function()
            local header = tmp_header("extern int titan_cdriver_absolute(void);\n")

            local _, include = assert_process_file(header)

            assert.equal(header, include.original)
            assert.equal(header, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal(header, include.include_name)

            os.remove(header)
        end)

        it("resolves relative headers under source_dir as quoted includes", function()
            local dir = tmp_dir()
            local header = "titan_cdriver_local.h"
            local resolved = dir .. "/" .. header
            write_file(resolved, "extern int titan_cdriver_local(void);\n")

            local _, include = assert_process_file(header, { source_dir = dir })

            assert.equal(header, include.original)
            assert.equal(resolved, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal(header, include.include_name)

            os.remove(resolved)
            lfs.rmdir(dir)
        end)

        it("uses angle descriptors for system headers", function()
            local root = tmp_dir()
            local header = root .. "/fixture-system.h"
            write_file(header, "typedef int fixture_system_value;\n")
            local _, include = assert_process_file("fixture-system.h", {
                cppflags = { "-I", root },
                compiler_include_dirs = {},
            })

            assert.equal("fixture-system.h", include.original)
            assert.equal(header, include.resolved)
            assert.equal("angle", include.include_kind)
            assert.equal("fixture-system.h", include.include_name)

            remove_tree({ header }, { root })
        end)

        it("uses angle descriptors for compiler-provided headers", function()
            local root = tmp_dir()
            local titan = mkdir(root, "titan")
            local header = titan .. "/ffi.h"
            write_file(header, "typedef int fixture_compiler_value;\n")
            local _, include = assert_process_file("titan/ffi.h", {
                compiler_include_dirs = { root },
            })

            assert.equal("titan/ffi.h", include.original)
            assert.equal(header, include.resolved)
            assert.equal("angle", include.include_kind)
            assert.equal("titan/ffi.h", include.include_name)

            remove_tree({ header }, { titan, root })
        end)

        it("does no cwd I/O for an absolute language-server module path",
        function()
            local checkout = assert(lfs.currentdir())
            local module_path = checkout .. "/c-parser/cdriver.lua"
            local chunk = assert(loadfile(module_path))
            local original_new_sync = compiler_io.new_sync
            compiler_io.new_sync = function()
                local strategy = original_new_sync()
                function strategy:cwd()
                    error("absolute module load queried synchronous cwd")
                end
                return strategy
            end

            local loaded, fresh = pcall(
                chunk, "c-parser.cdriver", module_path)

            compiler_io.new_sync = original_new_sync
            assert.truthy(loaded, fresh)
            assert.is_table(fresh)

            local strategy = original_new_sync()
            function strategy:cwd()
                error("absolute module discovery queried request cwd")
            end
            local dirs, discovery_error =
                fresh.resolve_compiler_include_dirs(nil, strategy)
            assert.truthy(dirs, discovery_error)
            assert.matches("/titan%-runtime$", dirs[1])
        end)

        it("captures a relative module root without trusting PWD", function()
            local checkout = assert(lfs.currentdir())
            local chunk = assert(loadfile("c-parser/cdriver.lua"))
            local original_new_sync = compiler_io.new_sync
            local original_getenv = os.getenv
            local cwd_calls = 0
            compiler_io.new_sync = function()
                local strategy = original_new_sync()
                function strategy:cwd()
                    cwd_calls = cwd_calls + 1
                    return checkout
                end
                return strategy
            end
            os.getenv = function(name)
                if name == "PWD" then
                    error("cdriver module root must not read PWD")
                end
                return original_getenv(name)
            end

            local loaded, fresh = pcall(
                chunk, "c-parser.cdriver", "c-parser/cdriver.lua")

            compiler_io.new_sync = original_new_sync
            os.getenv = original_getenv
            assert.truthy(loaded, fresh)
            assert.equal(1, cwd_calls)

            local olddir = assert(lfs.currentdir())
            assert(lfs.chdir("/tmp"))
            local resolved, failure = pcall(function()
                local strategy = original_new_sync()
                function strategy:cwd()
                    error("discovery rebound the captured module root")
                end
                return assert(fresh.resolve_compiler_include_dirs(
                    nil, strategy))
            end)
            assert(lfs.chdir(olddir))
            assert.truthy(resolved, failure)
            assert.matches("/titan%-runtime$", failure[1])
        end)

        it("defers a failed relative-root capture for explicit roots",
        function()
            local chunk = assert(loadfile("c-parser/cdriver.lua"))
            local original_new_sync = compiler_io.new_sync
            compiler_io.new_sync = function()
                local strategy = original_new_sync()
                function strategy:cwd()
                    return nil, "simulated load-time cwd failure"
                end
                return strategy
            end

            local loaded, fresh = pcall(
                chunk, "c-parser.cdriver", "c-parser/cdriver.lua")

            compiler_io.new_sync = original_new_sync
            assert.truthy(loaded, fresh)
            local strategy = original_new_sync()
            function strategy:cwd()
                error("default discovery retried cwd after module load")
            end
            assert.same({ "/explicit/compiler/include" },
                assert(fresh.resolve_compiler_include_dirs({
                    "/explicit/compiler/include",
                }, strategy)))
            local dirs, discovery_error =
                fresh.resolve_compiler_include_dirs(nil, strategy)
            assert.is_nil(dirs)
            assert.matches("simulated load%-time cwd failure",
                discovery_error)
        end)
    end)

    describe("header dependency identity", function()
        it("reports exact direct and transitive bytes parsed", function()
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local nested = root .. "/nested.h"
            local outer_contents =
                '#include "nested.h"\nextern int titan_outer(void);\n'
            local first_nested = "typedef int titan_nested_value;\n"
            write_file(outer, outer_contents)
            write_file(nested, first_nested)

            local _, include, context = assert_process_file(
                "outer.h", { source_dir = root })
            assert.same({
                { kind = "file", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "file", outer)) },
                { kind = "file", path = nested,
                  identity = assert(cdriver.header_input_identity(
                      "file", nested)) },
            }, include.c_header_dependencies)
            assert.equal(
                include.c_header_dependencies,
                context.c_header_dependencies)
            assert.same({
                { kind = "search", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "search", outer)) },
                { kind = "search", path = nested,
                  identity = assert(cdriver.header_input_identity(
                      "search", nested)) },
            }, include.c_header_search_inputs)

            local second_nested = "typedef long titan_nested_value;\n"
            write_file(nested, second_nested)
            local _, changed = assert_process_file(
                "outer.h", { source_dir = root })
            assert.equal(
                include.c_header_dependencies[1].identity,
                changed.c_header_dependencies[1].identity)
            assert.equal(
                assert(cdriver.header_input_identity("file", nested)),
                changed.c_header_dependencies[2].identity)
            assert.not_equal(
                include.c_header_dependencies[2].identity,
                changed.c_header_dependencies[2].identity)

            remove_tree({ outer, nested }, { root })
        end)

        it("records missing earlier candidates so additions shadow safely",
        function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local outer = source .. "/outer.h"
            local early_header = early .. "/selected.h"
            local late_header = late .. "/selected.h"
            write_file(outer, "#include <selected.h>\n")
            write_file(late_header,
                "typedef int titan_selected_header_value;\n")
            local options = {
                source_dir = source,
                compiler_include_dirs = {},
                cppflags = { "-I", early, "-I", late },
                process_analysis = cdriver.new_process_analysis(),
            }

            local _, first = assert_process_file("outer.h", options)
            assert.same({
                { kind = "search", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "search", outer)) },
                { kind = "search", path = early_header,
                  identity = assert(cdriver.header_input_identity(
                      "search", early_header)) },
                { kind = "search", path = late_header,
                  identity = assert(cdriver.header_input_identity(
                      "search", late_header)) },
            }, first.c_header_search_inputs)
            assert.equal(late_header,
                first.c_header_dependencies[2].path)

            write_file(early_header,
                "typedef long titan_selected_header_value;\n")
            options.process_analysis = cdriver.new_process_analysis()
            local _, shadowed = assert_process_file("outer.h", options)
            assert.equal(early_header,
                shadowed.c_header_dependencies[2].path)
            assert.equal(2, #shadowed.c_header_search_inputs)
            assert.not_equal(
                first.c_header_search_inputs[2].identity,
                shadowed.c_header_search_inputs[2].identity)

            remove_tree(
                { outer, early_header, late_header },
                { source, early, late, root })
        end)

        it("preserves symlink traversal when absolutizing include paths",
        function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local first = mkdir(root, "first")
            local first_nested = mkdir(first, "nested")
            local first_include = mkdir(first, "include")
            local second = mkdir(root, "second")
            local second_nested = mkdir(second, "nested")
            local second_include = mkdir(second, "include")
            local lexical_dir = mkdir(root, "include")
            local link = root .. "/sdk-link"
            assert(lfs.link("first/nested", link, true))

            local outer = source .. "/outer.h"
            local first_selected = first_include .. "/selected.h"
            local second_selected = second_include .. "/selected.h"
            local lexical = lexical_dir .. "/selected.h"
            local lookup = link .. "/../include/selected.h"
            local selected_contents =
                "typedef int titan_symlink_parent_value;\n"
            write_file(outer, "#include <selected.h>\n")
            write_file(first_selected, selected_contents)
            write_file(second_selected, selected_contents)
            write_file(lexical,
                "typedef double titan_symlink_parent_value;\n")

            local types, include = assert_process_file("outer.h", {
                source_dir = source,
                compiler_include_dirs = {},
                cppflags = { "-I", link .. "/../include" },
            })
            assert.same({ "int" },
                types.titan_symlink_parent_value.def)
            assert.equal(lookup,
                include.c_header_dependencies[2].path)
            assert.equal(lookup,
                include.c_header_search_inputs[2].path)
            local first_file_identity =
                include.c_header_dependencies[2].identity
            local first_search_identity =
                include.c_header_search_inputs[2].identity
            assert.equal(assert(cdriver.header_input_identity("file", lookup)),
                first_file_identity)
            assert.equal(assert(cdriver.header_input_identity(
                "search", lookup)), first_search_identity)

            local direct_types, direct_include = assert_process_file(lookup, {
                compiler_include_dirs = {},
            })
            assert.same({ "int" },
                direct_types.titan_symlink_parent_value.def)
            assert.equal(lookup, direct_include.resolved)
            assert.equal(lookup,
                direct_include.c_header_dependencies[1].path)

            assert(os.remove(link))
            assert(lfs.link("second/nested", link, true))
            assert.not_equal(first_file_identity,
                assert(cdriver.header_input_identity("file", lookup)))
            assert.not_equal(first_search_identity,
                assert(cdriver.header_input_identity("search", lookup)))

            remove_tree(
                { outer, first_selected, second_selected, lexical, link },
                { root, first, first_nested, first_include,
                  second, second_nested, second_include,
                  lexical_dir, source })
        end)

        it("preserves a symlinked header's quoted-include origin", function()
            local root = tmp_dir()
            local alias = mkdir(root, "alias")
            local vendor = mkdir(root, "vendor")
            local alias_header = alias .. "/api.h"
            local alias_nested = alias .. "/nested.h"
            local vendor_header = vendor .. "/api.h"
            local vendor_nested = vendor .. "/nested.h"
            write_file(vendor_header, '#include "nested.h"\n')
            write_file(alias_nested,
                "typedef int titan_symlink_origin_value;\n")
            write_file(vendor_nested,
                "typedef double titan_symlink_origin_value;\n")
            assert(lfs.link("../vendor/api.h", alias_header, true))

            local types, include = assert_process_file(alias_header, {
                compiler_include_dirs = {},
            })
            assert.same({ "int" }, types.titan_symlink_origin_value.def)
            assert.equal(alias_header, include.resolved)
            assert.same({ alias_header, alias_nested }, {
                include.c_header_dependencies[1].path,
                include.c_header_dependencies[2].path,
            })

            remove_tree(
                { alias_header, alias_nested, vendor_header, vendor_nested },
                { alias, vendor, root })
        end)

        it("distinguishes a same-byte replacement from a hard link",
        function()
            local root = tmp_dir()
            local original = root .. "/original.h"
            local linked = root .. "/linked.h"
            local replacement = root .. "/replacement.h"
            local contents = "typedef int titan_physical_header_value;\n"
            write_file(original, contents)
            assert(lfs.link(original, linked))

            local original_file = assert(cdriver.header_input_identity(
                "file", original))
            local original_search = assert(cdriver.header_input_identity(
                "search", original))
            assert.equal(original_file,
                assert(cdriver.header_input_identity("file", linked)))
            assert.equal(original_search,
                assert(cdriver.header_input_identity("search", linked)))

            write_file(replacement, contents)
            assert(os.rename(replacement, linked))
            assert.not_equal(original_file,
                assert(cdriver.header_input_identity("file", linked)))
            assert.not_equal(original_search,
                assert(cdriver.header_input_identity("search", linked)))

            remove_tree({ original, linked, replacement }, { root })
        end)

        it("records the exact include lookup access result", function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local outer = source .. "/outer.h"
            local early_header = early .. "/selected.h"
            local late_header = late .. "/selected.h"
            write_file(outer, "#include <selected.h>\n")
            write_file(early_header,
                "typedef long titan_access_selected;\n")
            write_file(late_header,
                "typedef int titan_access_selected;\n")

            local original_open = io.open
            io.open = function(filename, mode)
                if filename == early_header and mode == "rb" then
                    return nil, "simulated access denial"
                end
                return original_open(filename, mode)
            end
            local include
            local ok, err = pcall(function()
                local _types
                _types, include = assert_process_file("outer.h", {
                    source_dir = source,
                    compiler_include_dirs = {},
                    cppflags = { "-I", early, "-I", late },
                })
            end)
            io.open = original_open
            assert.truthy(ok, err)
            assert.equal(late_header,
                include.c_header_dependencies[2].path)
            assert.matches("lstat=file",
                include.c_header_search_inputs[2].identity, 1, true)
            assert.matches("stat=file",
                include.c_header_search_inputs[2].identity, 1, true)
            assert.matches("open=unreadable",
                include.c_header_search_inputs[2].identity, 1, true)
            local now_readable = assert(cdriver.header_input_identity(
                "search", early_header))
            assert.matches("open=readable", now_readable, 1, true)
            assert.not_equal(
                include.c_header_search_inputs[2].identity, now_readable)

            remove_tree(
                { outer, early_header, late_header },
                { source, early, late, root })
        end)

        it("distinguishes broken and followed include symlinks", function()
            local root = tmp_dir()
            local target = root .. "/future.h"
            local link = root .. "/candidate.h"
            assert(lfs.link(target, link, true))
            local broken = assert(cdriver.header_input_identity(
                "search", link))
            assert.matches("lstat=link", broken, 1, true)
            assert.matches("stat=missing", broken, 1, true)

            write_file(target, "typedef int titan_future_header;\n")
            local followed = assert(cdriver.header_input_identity(
                "search", link))
            assert.matches("lstat=link", followed, 1, true)
            assert.matches("stat=file", followed, 1, true)
            assert.not_equal(broken, followed)

            assert(os.remove(link))
            assert(os.remove(target))
            assert(lfs.rmdir(root))
        end)

        it("includes the actual lookup open predicate", function()
            local header = tmp_header(
                "typedef int titan_openable_header;\n")
            local readable = assert(cdriver.header_input_identity(
                "search", header))
            assert.matches("open=readable", readable, 1, true)

            -- Keep lstat/stat metadata unchanged while simulating an
            -- effective-access denial. The identity must follow the same
            -- io.open predicate that ordered include selection uses, not only
            -- ownership/mode bits (which do not describe ACL decisions).
            local original_open = io.open
            local unreadable
            io.open = function(filename, mode)
                if filename == header and mode == "rb" then
                    return nil, "simulated access denial"
                end
                return original_open(filename, mode)
            end
            local ok, err = pcall(function()
                unreadable = assert(cdriver.header_input_identity(
                    "search", header))
            end)
            io.open = original_open
            assert.truthy(ok, err)
            assert.matches("open=unreadable", unreadable, 1, true)
            assert.not_equal(readable, unreadable)

            assert(os.remove(header))
        end)
    end)


    describe("completed header cache", function()
        after_each(function()
            cdriver._set_process_cache_limits_for_test()
        end)

        it("traces one complete top-level duration per returned request",
        function()
            cdriver.clear_process_cache()
            local header = tmp_header(
                "typedef int titan_process_total_type;\n")
            local stable_identity = "/project/provider.titan.h"
            local totals = {}
            local options = {
                compiler_include_dirs = {},
                process_trace_identity = stable_identity,
                process_trace = function(
                        requested, resolved, phase, outcome, cpu_ms, identity)
                    if phase == "process_total" then
                        totals[#totals + 1] = {
                            requested = requested,
                            resolved = resolved,
                            outcome = outcome,
                            cpu_ms = cpu_ms,
                            identity = identity,
                        }
                    end
                end,
            }

            assert_process_file(header, options)
            assert_process_file(header, options)
            assert.equal(2, #totals)
            for _, total in ipairs(totals) do
                assert.equal(header, total.requested)
                assert.equal(header, total.resolved)
                assert.equal("complete", total.outcome)
                assert.is_true(total.cpu_ms >= 0)
                assert.equal(stable_identity, total.identity)
            end

            local failed = {}
            local missing = header .. ".missing"
            local processed, process_error = cdriver.process_file(missing, {
                compiler_include_dirs = {},
                process_trace = function(
                        _, _, phase, outcome, cpu_ms, identity)
                    if phase == "process_total" then
                        failed[#failed + 1] = {
                            outcome = outcome,
                            cpu_ms = cpu_ms,
                            identity = identity,
                        }
                    end
                end,
            })
            assert.is_nil(processed)
            assert.is_string(process_error)
            assert.equal(1, #failed)
            assert.equal("failed", failed[1].outcome)
            assert.is_true(failed[1].cpu_ms >= 0)
            assert.equal(missing, failed[1].identity)

            local traced = assert_process_file(header, {
                compiler_include_dirs = {},
                process_trace = function(_, _, phase)
                    if phase == "process_total" then
                        error("telemetry sink failure")
                    end
                end,
            })
            assert.is_table(traced)
            os.remove(header)
        end)

        it("rejects forged analysis reuse authorities", function()
            cdriver.clear_process_cache()
            local header = tmp_header(
                "typedef int titan_invalid_analysis_type;\n")

            local types, err = cdriver.process_file(header, {
                process_analysis = {},
            })

            assert.is_nil(types)
            assert.equal("process_analysis is not a cdriver analysis", err)
            assert.equal(0, cdriver.process_cache_stats().lookups)
            os.remove(header)
        end)

        describe("analysis-owned probe caches", function()
            it("shares exact toolchain caches across callers", function()
                local compiler_io = require "titan-compiler.io"
                local strategy = compiler_io.new_sync()
                local analysis = cdriver.new_process_analysis()

                local baseline_cache, result_cache =
                    cdriver.process_analysis_probe_caches(
                        analysis, strategy, "toolchain-one")
                assert.is_table(baseline_cache)
                assert.is_table(result_cache)
                assert.not_equal(baseline_cache, result_cache)
                baseline_cache.baseline = { status = "success" }
                result_cache.candidate = {
                    status = "compiler_rejection",
                }

                local repeated_baselines, repeated_results =
                    cdriver.process_analysis_probe_caches(
                        analysis, strategy, "toolchain-one")
                assert.equal(baseline_cache, repeated_baselines)
                assert.equal(result_cache, repeated_results)
                assert.equal("success",
                    repeated_baselines.baseline.status)
                assert.equal("compiler_rejection",
                    repeated_results.candidate.status)
            end)

            it("isolates providers, toolchains, and analyses", function()
                local compiler_io = require "titan-compiler.io"
                local first_strategy = compiler_io.new_sync()
                local second_strategy = compiler_io.new_sync()
                local first_analysis = cdriver.new_process_analysis()
                local second_analysis = cdriver.new_process_analysis()

                local baseline_cache, result_cache =
                    cdriver.process_analysis_probe_caches(
                        first_analysis, first_strategy, "toolchain-one")
                local other_toolchain_baselines, other_toolchain_results =
                    cdriver.process_analysis_probe_caches(
                        first_analysis, first_strategy, "toolchain-two")
                local other_provider_baselines, other_provider_results =
                    cdriver.process_analysis_probe_caches(
                        first_analysis, second_strategy, "toolchain-one")
                local other_analysis_baselines, other_analysis_results =
                    cdriver.process_analysis_probe_caches(
                        second_analysis, first_strategy, "toolchain-one")

                assert.not_equal(baseline_cache, other_toolchain_baselines)
                assert.not_equal(result_cache, other_toolchain_results)
                assert.not_equal(baseline_cache, other_provider_baselines)
                assert.not_equal(result_cache, other_provider_results)
                assert.not_equal(baseline_cache, other_analysis_baselines)
                assert.not_equal(result_cache, other_analysis_results)
            end)

            it("validates the authority, provider, and exact key", function()
                local compiler_io = require "titan-compiler.io"
                local strategy = compiler_io.new_sync()
                local analysis = cdriver.new_process_analysis()

                local missing, err =
                    cdriver.process_analysis_probe_caches(
                        {}, strategy, "toolchain")
                assert.is_nil(missing)
                assert.equal(
                    "process_analysis is not a cdriver analysis", err)

                missing, err = cdriver.process_analysis_probe_caches(
                    analysis, {}, "toolchain")
                assert.is_nil(missing)
                assert.matches("invalid compiler I/O strategy", err, 1, true)

                for _, key in ipairs({ false, 17, {} }) do
                    missing, err = cdriver.process_analysis_probe_caches(
                        analysis, strategy, key)
                    assert.is_nil(missing)
                    assert.equal(
                        "C probe toolchain key must be a nonempty string",
                        err)
                end
                missing, err = cdriver.process_analysis_probe_caches(
                    analysis, strategy, "")
                assert.is_nil(missing)
                assert.equal(
                    "C probe toolchain key must be a nonempty string", err)
            end)
        end)

        it("returns isolated graphs without reparsing an unchanged header",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local header = tmp_header([[
#define TITAN_CDRIVER_CACHE_CONSTANT 17
typedef int titan_cdriver_cache_type;
extern titan_cdriver_cache_type titan_cdriver_cache_value;
]])

            local ok, err = pcall(function()
                local first, first_include, first_context =
                    assert_process_file(header)
                assert.equal(1, matches)
                first.titan_cdriver_cache_type.def[1] = "long"
                first.macro_definitions.TITAN_CDRIVER_CACHE_CONSTANT[1] = "23"

                local second, second_include, second_context =
                    assert_process_file(header)
                assert.equal(1, matches)
                assert.not_equal(first, second)
                assert.not_equal(
                    first.titan_cdriver_cache_type,
                    second.titan_cdriver_cache_type)
                assert.same(
                    { "int" }, second.titan_cdriver_cache_type.def)
                assert.same({ "17" },
                    second.macro_definitions.TITAN_CDRIVER_CACHE_CONSTANT)
                assert.equal(
                    second.macro_definitions, second_context.defines)
                assert.equal(second_include.c_header_dependencies,
                    second_context.c_header_dependencies)
                assert.equal(second_include.c_header_search_inputs,
                    second_context.c_header_search_inputs)

                second.titan_cdriver_cache_type.def[1] = "double"
                local third = assert_process_file(header)
                assert.equal(1, matches)
                assert.same({ "int" }, third.titan_cdriver_cache_type.def)

                local stats = cdriver.process_cache_stats()
                assert.equal(3, stats.lookups)
                assert.equal(2, stats.hits)
                assert.equal(1, stats.misses)
                assert.equal(1, stats.stores)
                assert.equal(1, stats.size)
                assert.equal(0, stats.invalidations)

                assert.not_equal(first_include, second_include)
                assert.not_equal(first_context, second_context)
            end)
            c99.match_language_grammar = original_match
            os.remove(header)
            assert.truthy(ok, err)
        end)

        it("preserves macro token spelling across completed-cache clones",
        function()
            cdriver.clear_process_cache()
            local cpp = require "c-parser.cpp"
            local header = tmp_header(
                "typedef int titan_macro_spacing_cache_type;\n")
            local options = {
                cppflags = {
                    "-DTITAN_CACHE_STRINGIFY(x)=#x",
                    "-DTITAN_CACHE_VALUE=TITAN_CACHE_STRINGIFY(a + b)",
                },
            }

            local first = assert_process_file(header, options)
            local second = assert_process_file(header, options)
            assert.equal('"a + b"', cpp.expand_macro(
                "TITAN_CACHE_VALUE", first.macro_definitions))
            assert.equal('"a + b"', cpp.expand_macro(
                "TITAN_CACHE_VALUE", second.macro_definitions))
            assert.equal(1, cdriver.process_cache_stats().hits)
            os.remove(header)
        end)

        it("validates and clones once for each explicit analysis",
        function()
            cdriver.clear_process_cache()
            local original_identity = cdriver.header_input_identity
            local identity_reads = 0
            cdriver.header_input_identity = function(...)
                identity_reads = identity_reads + 1
                return original_identity(...)
            end
            local phases = {}
            local function trace(_, _, phase, outcome)
                local key = phase .. ":" .. outcome
                phases[key] = (phases[key] or 0) + 1
            end
            local header = tmp_header(
                "typedef int titan_analysis_cache_type;\n")
            local base = { compiler_include_dirs = {} }

            local ok, err = pcall(function()
                assert_process_file(header, base)
                local after_seed = identity_reads

                local first_analysis = cdriver.new_process_analysis()
                local first_options = {
                    compiler_include_dirs = {},
                    process_analysis = first_analysis,
                    process_trace = trace,
                }
                local first = assert_process_file(header, first_options)
                local after_first = identity_reads
                local repeated = assert_process_file(header, first_options)
                local repeated_again =
                    assert_process_file(header, first_options)
                assert.is_true(after_first > after_seed)
                assert.equal(after_first, identity_reads)
                assert.equal(first, repeated)
                assert.equal(first, repeated_again)

                first.titan_analysis_cache_type.def[1] = "long"
                local second_options = {
                    compiler_include_dirs = {},
                    process_analysis = cdriver.new_process_analysis(),
                    process_trace = trace,
                }
                local second = assert_process_file(header, second_options)
                assert.is_true(identity_reads > after_first)
                assert.not_equal(first, second)
                assert.same(
                    { "int" }, second.titan_analysis_cache_type.def)

                local ordinary = assert_process_file(header, base)
                assert.not_equal(second, ordinary)
                assert.same(
                    { "int" }, ordinary.titan_analysis_cache_type.def)
                assert.equal(2, phases["hit_validation:current"])
                assert.equal(2, phases["hit_validation:analysis_reuse"])
                assert.equal(2, phases["graph_clone:hit"])
                assert.equal(2, phases["graph_clone:analysis_reuse"])
            end)
            cdriver.header_input_identity = original_identity
            os.remove(header)
            assert.truthy(ok, err)
        end)

        it("treats one analysis as a snapshot and revalidates the next",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local nested = root .. "/nested.h"
            write_file(outer, '#include "nested.h"\n')
            write_file(nested,
                "typedef int titan_analysis_snapshot_type;\n")
            local base = {
                source_dir = root,
                compiler_include_dirs = {},
            }

            local ok, err = pcall(function()
                assert_process_file("outer.h", base)
                local first_options = {
                    source_dir = root,
                    compiler_include_dirs = {},
                    process_analysis = cdriver.new_process_analysis(),
                }
                local first, first_include =
                    assert_process_file("outer.h", first_options)
                write_file(nested,
                    "typedef long titan_analysis_snapshot_type;\n")

                local same_analysis, same_include =
                    assert_process_file("outer.h", first_options)
                assert.equal(first, same_analysis)
                assert.same({ "int" },
                    same_analysis.titan_analysis_snapshot_type.def)
                assert.same(first_include.c_header_dependencies,
                    same_include.c_header_dependencies)

                local old_nested_identity
                for _, input in ipairs(
                        same_include.c_header_dependencies) do
                    if input.path == nested then
                        old_nested_identity = input.identity
                    end
                end
                assert.truthy(old_nested_identity)
                assert.not_equal(old_nested_identity,
                    assert(cdriver.header_input_identity("file", nested)))

                local next_analysis = assert_process_file("outer.h", {
                    source_dir = root,
                    compiler_include_dirs = {},
                    process_analysis = cdriver.new_process_analysis(),
                })
                assert.same({ "long" },
                    next_analysis.titan_analysis_snapshot_type.def)
                assert.equal(2, matches)
            end)
            c99.match_language_grammar = original_match
            remove_tree({ outer, nested }, { root })
            assert.truthy(ok, err)
        end)

        it("isolates probed predefined macros from caller mutation",
        function()
            cdriver.clear_process_cache()
            local cpp = require "c-parser.cpp"
            cpp.clear_probe_cache()
            local header = tmp_header(
                "typedef int titan_probe_macro_cache_type;\n")
            local options = {
                cppflags = { "-DTITAN_CACHE_PROBE_MUTATION=17" },
            }

            local first = assert_process_file(header, options)
            assert.same({ "17" },
                first.macro_definitions.TITAN_CACHE_PROBE_MUTATION)
            first.macro_definitions.TITAN_CACHE_PROBE_MUTATION[1] = "23"
            cdriver.clear_process_cache()
            local second = assert_process_file(header, options)
            assert.same({ "17" },
                second.macro_definitions.TITAN_CACHE_PROBE_MUTATION)
            os.remove(header)
        end)

        it("charges retained macro string bytes to the cache budget",
        function()
            cdriver.clear_process_cache()
            cdriver._set_process_cache_limits_for_test(
                math.maxinteger, math.maxinteger)
            local payload = string.rep("x", 100000)
            local header = tmp_header(
                '#define TITAN_CACHE_LARGE_STRING "' .. payload .. '"\n' ..
                '#define TITAN_CACHE_LARGE_STRING_AGAIN "' .. payload .. '"\n' ..
                "typedef int titan_large_string_cache_type;\n")

            assert_process_file(header)
            local stats = cdriver.process_cache_stats()
            assert.is_true(stats.tracks_weight)
            assert.is_true(stats.weight > 2 * #payload)
            os.remove(header)
        end)

        it("rebuilds caller-specific top-level search observations on a hit",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local root = tmp_dir()
            local first_source = mkdir(root, "first")
            local second_source = mkdir(root, "second")
            local fallback = mkdir(root, "fallback")
            local name = "shared-cache.h"
            local header = fallback .. "/" .. name
            write_file(header, "typedef int titan_shared_cache_type;\n")
            local analysis = cdriver.new_process_analysis()

            local ok, err = pcall(function()
                local _, first_include = assert_process_file(name, {
                    source_dir = first_source,
                    cppflags = { "-I", fallback },
                    compiler_include_dirs = {},
                    process_analysis = analysis,
                })
                local dependency_identity =
                    first_include.c_header_dependencies[1].identity
                local fallback_search_identity =
                    first_include.c_header_search_inputs[2].identity
                first_include.c_header_dependencies[1].identity =
                    "poisoned dependency"
                first_include.c_header_search_inputs[2].identity =
                    "poisoned search"
                local _, second_include, second_context =
                    assert_process_file(name, {
                        source_dir = second_source,
                        cppflags = { "-I", fallback },
                        compiler_include_dirs = {},
                        process_analysis = analysis,
                    })
                assert.equal(1, matches)
                assert.equal(header, first_include.resolved)
                assert.equal(header, second_include.resolved)
                assert.equal(dependency_identity,
                    second_include.c_header_dependencies[1].identity)
                assert.equal(fallback_search_identity,
                    second_include.c_header_search_inputs[2].identity)

                local observed = {}
                for _, input in ipairs(
                        second_include.c_header_search_inputs) do
                    observed[input.path] = true
                end
                assert.is_true(observed[second_source .. "/" .. name])
                assert.is_nil(observed[first_source .. "/" .. name])
                assert.equal(second_include.c_header_search_inputs,
                    second_context.c_header_search_inputs)
                assert.equal(1, cdriver.process_cache_stats().hits)
            end)
            c99.match_language_grammar = original_match
            remove_tree({ header }, {
                first_source, second_source, fallback, root,
            })
            assert.truthy(ok, err)
        end)

        it("separates interpretations by complete preprocessor context",
        function()
            cdriver.clear_process_cache()
            local header = tmp_header([[
typedef TITAN_CACHE_CONFIG_TYPE titan_cache_config_type;
]])
            local base = {
                compiler = { "cc" },
                language_mode = "c99",
                compiler_include_dirs = {},
            }
            local analysis = cdriver.new_process_analysis()

            local first = assert_process_file(header, {
                compiler = base.compiler,
                language_mode = base.language_mode,
                compiler_include_dirs = base.compiler_include_dirs,
                cppflags = { "-DTITAN_CACHE_CONFIG_TYPE=int" },
                process_analysis = analysis,
            })
            local second = assert_process_file(header, {
                compiler = base.compiler,
                language_mode = base.language_mode,
                compiler_include_dirs = base.compiler_include_dirs,
                cppflags = { "-DTITAN_CACHE_CONFIG_TYPE=long" },
                process_analysis = analysis,
            })
            assert.same({ "int" }, first.titan_cache_config_type.def)
            assert.same({ "long" }, second.titan_cache_config_type.def)

            local repeated = assert_process_file(header, {
                compiler = base.compiler,
                language_mode = base.language_mode,
                compiler_include_dirs = base.compiler_include_dirs,
                cppflags = { "-DTITAN_CACHE_CONFIG_TYPE=int" },
                process_analysis = analysis,
            })
            assert.same({ "int" }, repeated.titan_cache_config_type.def)
            local stats = cdriver.process_cache_stats()
            assert.equal(3, stats.lookups)
            assert.equal(1, stats.hits)
            assert.equal(2, stats.misses)
            assert.equal(2, stats.stores)
            assert.equal(2, stats.size)

            os.remove(header)
        end)

        it("invalidates exact transitive bytes before reusing a result",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local nested = root .. "/nested.h"
            write_file(outer, '#include "nested.h"\n')
            write_file(nested, "typedef int titan_cached_nested_type;\n")

            local ok, err = pcall(function()
                local options = {
                    source_dir = root,
                    compiler_include_dirs = {},
                }
                local first = assert_process_file("outer.h", options)
                local second = assert_process_file("outer.h", options)
                assert.equal(1, matches)
                assert.same(
                    { "int" }, first.titan_cached_nested_type.def)
                assert.same(
                    { "int" }, second.titan_cached_nested_type.def)

                write_file(nested,
                    "typedef long titan_cached_nested_type;\n")
                local changed = assert_process_file("outer.h", options)
                assert.equal(2, matches)
                assert.same(
                    { "long" }, changed.titan_cached_nested_type.def)
                local repeated = assert_process_file("outer.h", options)
                assert.equal(2, matches)
                assert.same(
                    { "long" }, repeated.titan_cached_nested_type.def)

                local stats = cdriver.process_cache_stats()
                assert.equal(2, stats.hits)
                assert.equal(2, stats.misses)
                assert.equal(1, stats.invalidations)
                assert.equal(2, stats.stores)
            end)
            c99.match_language_grammar = original_match
            remove_tree({ outer, nested }, { root })
            assert.truthy(ok, err)
        end)

        it("scopes reuse to one compiler I/O provider", function()
            cdriver.clear_process_cache()
            local compiler_io = require "titan-compiler.io"
            local first_strategy = compiler_io.new_sync()
            local second_strategy = compiler_io.new_sync()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local header = tmp_header(
                "typedef int titan_provider_cache_type;\n")
            local analysis = cdriver.new_process_analysis()

            local ok, err = pcall(function()
                assert_process_file(header, {
                    io = first_strategy,
                    process_analysis = analysis,
                })
                assert_process_file(header, {
                    io = first_strategy,
                    process_analysis = analysis,
                })
                assert_process_file(header, {
                    io = second_strategy,
                    process_analysis = analysis,
                })
                assert.equal(2, matches)
                assert.equal(1,
                    cdriver.process_cache_stats(first_strategy).hits)
                assert.equal(0,
                    cdriver.process_cache_stats(second_strategy).hits)
            end)
            c99.match_language_grammar = original_match
            os.remove(header)
            assert.truthy(ok, err)
        end)

        it("keeps a same-key result completed while preprocessing yielded",
        function()
            cdriver.clear_process_cache()
            local cpp = require "c-parser.cpp"
            local original_parse = cpp.parse_file
            local nested = false
            local header = tmp_header(
                "typedef int titan_interleaved_cache_type;\n")

            cpp.parse_file = function(...)
                if not nested then
                    nested = true
                    assert_process_file(header)
                    nested = false
                end
                return original_parse(...)
            end
            local ok, err = pcall(function()
                local types = assert_process_file(header)
                assert.same(
                    { "int" }, types.titan_interleaved_cache_type.def)
                local stats = cdriver.process_cache_stats()
                assert.equal(2, stats.lookups)
                assert.equal(0, stats.hits)
                assert.equal(2, stats.misses)
                assert.equal(1, stats.stores)
                assert.equal(1, stats.size)
            end)
            cpp.parse_file = original_parse
            os.remove(header)
            assert.truthy(ok, err)
        end)

        it("retries a hit replaced while dependency validation yielded",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local original_identity = cdriver.header_input_identity
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local first = root .. "/race-first.h"
            local second = root .. "/race-second.h"
            write_file(outer, [[
#include "race-first.h"
#include "race-second.h"
]])
            write_file(first,
                "typedef int titan_replaced_cache_type;\n")
            write_file(second,
                "extern int titan_replaced_cache_marker;\n")
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
            }

            local ok, err = pcall(function()
                local seeded = assert_process_file("outer.h", options)
                assert.same(
                    { "int" }, seeded.titan_replaced_cache_type.def)
                assert.equal(1, matches)
                options.process_analysis = cdriver.new_process_analysis()

                local saw_first = false
                local interleaved = false
                local nested = false
                cdriver.header_input_identity = function(kind, path, strategy)
                    local identity, identity_error =
                        original_identity(kind, path, strategy)
                    if not nested and kind == "file" and path == first then
                        saw_first = true
                    elseif not nested and not interleaved and saw_first
                       and kind == "file" and path == second then
                        -- Replace the entry only after this outer lookup has
                        -- validated both dependency identities. The nested
                        -- lookup observes the changed first header, removes
                        -- the old entry, and publishes the replacement.
                        interleaved = true
                        write_file(first,
                            "typedef long titan_replaced_cache_type;\n")
                        nested = true
                        local replacement =
                            assert_process_file("outer.h", options)
                        nested = false
                        assert.same({ "long" },
                            replacement.titan_replaced_cache_type.def)
                    end
                    return identity, identity_error
                end

                local current = assert_process_file("outer.h", options)
                assert.is_true(interleaved)
                assert.same(
                    { "long" }, current.titan_replaced_cache_type.def)
                assert.equal(2, matches)

                local stats = cdriver.process_cache_stats()
                assert.equal(3, stats.lookups)
                assert.equal(1, stats.hits)
                assert.equal(2, stats.misses)
                assert.equal(1, stats.invalidations)
                assert.equal(2, stats.stores)
                assert.equal(1, stats.size)
            end)
            cdriver.header_input_identity = original_identity
            c99.match_language_grammar = original_match
            remove_tree({ outer, first, second }, { root })
            assert.truthy(ok, err)
        end)

        it("retries a memoized analysis hit replaced while tracing yielded",
        function()
            cdriver.clear_process_cache()
            local c99 = require "c-parser.c99"
            local original_match = c99.match_language_grammar
            local matches = 0
            c99.match_language_grammar = function(...)
                matches = matches + 1
                return original_match(...)
            end
            local header = tmp_header(
                "typedef int titan_replaced_analysis_type;\n")
            local analysis = cdriver.new_process_analysis()
            local options = {
                compiler_include_dirs = {},
                process_analysis = analysis,
            }

            local ok, err = pcall(function()
                assert_process_file(header, {
                    compiler_include_dirs = {},
                })
                local first = assert_process_file(header, options)
                assert.same(
                    { "int" }, first.titan_replaced_analysis_type.def)

                local interleaved = false
                local replacement
                local replacement_error
                options.process_trace = function(_, _, phase, outcome)
                    if not interleaved
                       and phase == "hit_validation"
                       and outcome == "analysis_reuse" then
                        interleaved = true
                        write_file(header,
                            "typedef long titan_replaced_analysis_type;\n")
                        replacement, replacement_error = cdriver.process_file(
                            header, {
                                compiler_include_dirs = {},
                                process_analysis =
                                    cdriver.new_process_analysis(),
                            })
                    end
                end

                local current = assert_process_file(header, options)
                assert.is_true(interleaved)
                assert.is_nil(replacement_error)
                assert.is_table(replacement)
                assert.same({ "long" },
                    replacement.titan_replaced_analysis_type.def)
                assert.same({ "long" },
                    current.titan_replaced_analysis_type.def)
                local repeated = assert_process_file(header, options)
                assert.equal(current, repeated)
                assert.equal(2, matches)

                local stats = cdriver.process_cache_stats()
                assert.equal(5, stats.lookups)
                assert.equal(3, stats.hits)
                assert.equal(2, stats.misses)
                assert.equal(1, stats.invalidations)
                assert.equal(2, stats.stores)
            end)
            c99.match_language_grammar = original_match
            os.remove(header)
            assert.truthy(ok, err)
        end)

        it("retains more than the former production entry bound", function()
            cdriver.clear_process_cache()
            local root = tmp_dir()
            local files = {}
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
            }
            for index = 1, 17 do
                local name = ("unbounded-cache-%02d.h"):format(index)
                local path = root .. "/" .. name
                files[#files + 1] = path
                write_file(path,
                    ("typedef int titan_unbounded_cache_%02d;\n")
                        :format(index))
            end

            local ok, err = pcall(function()
                local initial = cdriver.process_cache_stats()
                assert.equal(math.maxinteger, initial.entry_limit)
                assert.equal(math.maxinteger, initial.weight_limit)
                assert.is_false(initial.tracks_weight)

                for index = 1, 17 do
                    assert_process_file(
                        ("unbounded-cache-%02d.h"):format(index), options)
                end
                assert_process_file("unbounded-cache-01.h", options)

                local stats = cdriver.process_cache_stats()
                assert.equal(17, stats.size)
                assert.equal(17, stats.stores)
                assert.equal(17, stats.misses)
                assert.equal(1, stats.hits)
                assert.equal(0, stats.evictions)
                assert.equal(0, stats.oversized)
                assert.equal(0, stats.weight)
                assert.is_false(stats.tracks_weight)
            end)

            remove_tree(files, { root })
            assert.truthy(ok, err)
        end)

        it("refreshes a hit before least-recently-used count eviction",
        function()
            local root = tmp_dir()
            local files = {}
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
            }
            local weight_limit = cdriver.process_cache_stats().weight_limit
            cdriver._set_process_cache_limits_for_test(3, weight_limit)
            for index = 1, 4 do
                local name = ("bounded-cache-%02d.h"):format(index)
                local path = root .. "/" .. name
                files[#files + 1] = path
                write_file(path, ("typedef int titan_bounded_cache_%02d;\n")
                    :format(index))
            end

            local ok, err = pcall(function()
                assert_process_file("bounded-cache-01.h", options)
                assert_process_file("bounded-cache-02.h", options)
                assert_process_file("bounded-cache-03.h", options)

                -- Refresh the first entry, making the second uniquely oldest.
                assert_process_file("bounded-cache-01.h", options)
                assert_process_file("bounded-cache-04.h", options)
                local stats = cdriver.process_cache_stats()
                assert.equal(3, stats.size)
                assert.equal(4, stats.stores)
                assert.equal(1, stats.evictions)
                assert.equal(4, stats.misses)
                assert.equal(1, stats.hits)
                assert.equal(0, stats.oversized)

                -- The refreshed first entry survived; the untouched second
                -- entry missed and displaced the next-oldest third entry.
                assert_process_file("bounded-cache-01.h", options)
                assert_process_file("bounded-cache-02.h", options)
                stats = cdriver.process_cache_stats()
                assert.equal(3, stats.size)
                assert.equal(5, stats.stores)
                assert.equal(2, stats.evictions)
                assert.equal(5, stats.misses)
                assert.equal(2, stats.hits)
                assert.is_true(stats.weight <= stats.weight_limit)
            end)

            remove_tree(files, { root })
            assert.truthy(ok, err)
        end)

        it("evicts by retained weight below the entry-count bound", function()
            local root = tmp_dir()
            local first = root .. "/weight-first.h"
            local second = root .. "/weight-second.h"
            write_file(first, "typedef int titan_weight_first;\n")
            write_file(second, "typedef long titan_weight_second;\n")
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
            }

            local ok, err = pcall(function()
                local production_weight_limit =
                    cdriver.process_cache_stats().weight_limit
                cdriver._set_process_cache_limits_for_test(
                    8, production_weight_limit)
                assert_process_file("weight-first.h", options)
                local first_weight = cdriver.process_cache_stats().weight

                cdriver._set_process_cache_limits_for_test(
                    8, production_weight_limit)
                assert_process_file("weight-second.h", options)
                local second_weight = cdriver.process_cache_stats().weight

                -- Either entry fits alone, but their sum cannot fit. The
                -- second store must therefore evict by weight, not by count.
                local weight_limit = math.max(first_weight, second_weight)
                cdriver._set_process_cache_limits_for_test(8, weight_limit)
                assert_process_file("weight-first.h", options)
                assert_process_file("weight-second.h", options)
                local stats = cdriver.process_cache_stats()
                assert.equal(1, stats.size)
                assert.equal(2, stats.stores)
                assert.equal(1, stats.evictions)
                assert.equal(2, stats.misses)
                assert.equal(0, stats.hits)
                assert.equal(0, stats.oversized)
                assert.is_true(stats.weight <= stats.weight_limit)
                assert.equal(8, stats.entry_limit)

                assert_process_file("weight-second.h", options)
                assert_process_file("weight-first.h", options)
                stats = cdriver.process_cache_stats()
                assert.equal(1, stats.hits)
                assert.equal(3, stats.misses)
                assert.equal(3, stats.stores)
                assert.equal(2, stats.evictions)
            end)

            remove_tree({ first, second }, { root })
            assert.truthy(ok, err)
        end)

        it("rejects an entry larger than the retained-weight bound", function()
            local root = tmp_dir()
            local header = root .. "/oversized.h"
            write_file(header, "typedef int titan_oversized_cache_type;\n")
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
            }

            local ok, err = pcall(function()
                local production_weight_limit =
                    cdriver.process_cache_stats().weight_limit
                cdriver._set_process_cache_limits_for_test(
                    8, production_weight_limit)
                assert_process_file("oversized.h", options)
                local entry_weight = cdriver.process_cache_stats().weight

                cdriver._set_process_cache_limits_for_test(
                    8, entry_weight - 1)
                local first = assert_process_file("oversized.h", options)
                local second = assert_process_file("oversized.h", options)
                assert.same(
                    { "int" }, first.titan_oversized_cache_type.def)
                assert.same(
                    { "int" }, second.titan_oversized_cache_type.def)

                local stats = cdriver.process_cache_stats()
                assert.equal(0, stats.size)
                assert.equal(0, stats.weight)
                assert.equal(0, stats.stores)
                assert.equal(0, stats.evictions)
                assert.equal(2, stats.oversized)
                assert.equal(2, stats.misses)
                assert.equal(0, stats.hits)
            end)

            remove_tree({ header }, { root })
            assert.truthy(ok, err)
        end)

        it("never retains a failed preprocessing result", function()
            cdriver.clear_process_cache()
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local nested = root .. "/later.h"
            write_file(outer, '#include "later.h"\n')
            local options = {
                source_dir = root,
                compiler_include_dirs = {},
                process_analysis = cdriver.new_process_analysis(),
            }

            local first, first_error =
                cdriver.process_file("outer.h", options)
            assert.is_nil(first)
            assert.matches("later%.h", first_error)
            assert.equal(0, cdriver.process_cache_stats().stores)

            write_file(nested,
                "typedef int titan_later_cache_type;\n")
            local recovered = assert_process_file("outer.h", options)
            assert.same({ "int" }, recovered.titan_later_cache_type.def)
            local stats = cdriver.process_cache_stats()
            assert.equal(2, stats.misses)
            assert.equal(0, stats.hits)
            assert.equal(1, stats.stores)

            remove_tree({ outer, nested }, { root })
        end)
    end)

    it("retains suffixes on unnamed parameter declarators", function()
        local header = tmp_header([[
            extern int named_array(int value[7]);
            extern int unnamed_array(int [7]);
            extern int named_callback(int (*callback)(double));
            extern int unnamed_callback(int (*)(double));
            extern int named_array_pointer(int (*values)[7]);
            extern int unnamed_array_pointer(int (*)[7]);
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        for _, pair in ipairs({
            {"named_array", "unnamed_array"},
            {"named_callback", "unnamed_callback"},
            {"named_array_pointer", "unnamed_array_pointer"},
        }) do
            local named = ffi_types[pair[1]].params[1]
            local unnamed = ffi_types[pair[2]].params[1]
            assert.same(named._declarator_ops, unnamed._declarator_ops)
            assert.same(named.type, unnamed.type)
        end
        assert.equal(
            "functionptr",
            ffi_types.unnamed_callback.params[1].type)
        assert.same(
            {{idx = 7}, "*"},
            ffi_types.unnamed_array_pointer.params[1]._declarator_ops)
    end)

    it("publishes completed typedef-array declarators in either order",
    function()
        local header = tmp_header([[
            typedef int cdriver_array[];

            extern cdriver_array cdriver_alias_first;
            extern int cdriver_alias_first[7];
            extern int cdriver_direct_first[7];
            extern cdriver_array cdriver_direct_first;

            extern cdriver_array *cdriver_nested_alias_first;
            extern int (*cdriver_nested_alias_first)[7];
            extern int (*cdriver_nested_direct_first)[7];
            extern cdriver_array *cdriver_nested_direct_first;

            extern void cdriver_function_alias_first(
                cdriver_array *values);
            extern void cdriver_function_alias_first(
                int (*values)[7]);
            extern void cdriver_function_direct_first(
                int (*values)[7]);
            extern void cdriver_function_direct_first(
                cdriver_array *values);
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        for _, name in ipairs({
            "cdriver_alias_first",
            "cdriver_direct_first",
        }) do
            assert.same(
                {{idx = 7}},
                ffi_types[name]._declarator_ops)
        end
        for _, name in ipairs({
            "cdriver_nested_alias_first",
            "cdriver_nested_direct_first",
        }) do
            assert.same(
                {{idx = 7}, "*"},
                ffi_types[name]._declarator_ops)
        end
        for _, name in ipairs({
            "cdriver_function_alias_first",
            "cdriver_function_direct_first",
        }) do
            assert.same(
                {{idx = 7}, "*"},
                ffi_types[name].params[1]._declarator_ops)
        end
    end)

    it("uses active same-name type macros but suppresses macro-only aliases",
    function()
        local header = tmp_header([[
            typedef double cdriver_replacement_type;
            typedef int cdriver_public_type;
            typedef signed char cdriver_self_type;
            #define cdriver_public_type cdriver_replacement_type
            #define cdriver_macro_only_type cdriver_replacement_type
            #define cdriver_self_type cdriver_self_type
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        assert.equal("typedef", ffi_types.cdriver_replacement_type.type)
        assert.equal("typedef", ffi_types.cdriver_public_type.type)
        assert.same({"double"}, ffi_types.cdriver_public_type.def)
        assert.equal("typedef", ffi_types.cdriver_self_type.type)
        assert.same(
            {"signed", "char"}, ffi_types.cdriver_self_type.def)
        assert.is_nil(ffi_types.cdriver_macro_only_type)
        local occurrences = {}
        for _, item in ipairs(ffi_types) do
            occurrences[item.name] = (occurrences[item.name] or 0) + 1
        end
        assert.equal(1, occurrences.cdriver_replacement_type)
        assert.equal(2, occurrences.cdriver_public_type)
        assert.equal(1, occurrences.cdriver_self_type)
        assert.is_nil(occurrences.cdriver_macro_only_type)
    end)

    it("records final field projections and every touched macro name",
    function()
        local header = tmp_header([[
            #define cdriver_projection implementation.member
            #define cdriver_removed implementation.member
            #undef cdriver_removed
            #define cdriver_replaced implementation.member
            #undef cdriver_replaced
            #define cdriver_replaced 17
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        assert.same(
            { "implementation", "member" },
            ffi_types.field_macro_paths.cdriver_projection.path)
        assert.is_nil(ffi_types.field_macro_paths.cdriver_removed)
        assert.is_nil(ffi_types.field_macro_paths.cdriver_replaced)
        assert.is_true(ffi_types.macro_changes.cdriver_projection)
        assert.is_true(ffi_types.macro_changes.cdriver_removed)
        assert.is_true(ffi_types.macro_changes.cdriver_replaced)
        assert.same(
            { "implementation", ".", "member" },
            ffi_types.macro_definitions.cdriver_projection)
        assert.is_nil(ffi_types.macro_definitions.cdriver_removed)
        assert.same({ "17" },
            ffi_types.macro_definitions.cdriver_replaced)
    end)


    describe("configured preprocessor toolchain", function()
        local SYNTHETIC_LUA_PROFILE = [[
typedef long long lua_Integer;
typedef double lua_Number;
typedef unsigned long size_t;
typedef long ptrdiff_t;

#define SCHAR_MIN (-__SCHAR_MAX__ - 1)
#define SHRT_MIN (-__SHRT_MAX__ - 1)
#define INT_MIN (-__INT_MAX__ - 1)
#define LONG_MIN (-__LONG_MAX__ - 1L)
#define LLONG_MIN (-__LONG_LONG_MAX__ - 1LL)
]]

        local function synthetic_profile_root()
            local root = tmp_dir()
            local header = root .. "/lua.h"
            write_file(header, SYNTHETIC_LUA_PROFILE)
            return root, header
        end

        local function synthetic_preamble_roots(lua_root)
            local runtime_root = tmp_dir()
            local files = {}
            local function header(root, name, contents)
                local path = root .. "/" .. name
                write_file(path, contents or "")
                files[#files + 1] = path
            end

            header(runtime_root, "titan.h", [[
#if defined(__GNUC__) || defined(__clang__)
#define TITAN_UNUSED __attribute__((unused))
#else
#define TITAN_UNUSED
#endif
]])
            header(lua_root, "lstate.h", [[
typedef unsigned char lu_byte;
typedef struct TValue { int fixture; } TValue;
typedef TValue *StkId;
typedef struct FixtureStackPointer { StkId p; } FixtureStackPointer;
typedef struct CallInfo { FixtureStackPointer top; } CallInfo;
typedef struct lua_State {
    long errfunc;
    FixtureStackPointer top;
    CallInfo *ci;
} lua_State;
typedef int (*lua_CFunction)(lua_State *L);
typedef struct TString { int fixture; } TString;
typedef struct Table { unsigned int asize; } Table;
typedef struct global_State { TValue l_registry; } global_State;
typedef struct Node { int fixture; } Node;

static int errorhandler(lua_State *L) { (void)L; return 0; }
#define restorestack(L, offset) ((StkId)0)
#define s2v(slot) (slot)
#define ttislcf(value) 0
#define fvalue(value) ((lua_CFunction)0)
#define setnilvalue(value) ((void)(value))
#define luaS_new(L, key) ((TString *)0)
#define lua_assert(condition) ((void)0)
#define G(L) ((global_State *)0)
#define ttistable(value) 1
#define hvalue(value) ((Table *)0)
#define luaH_getstr(table, key, result) ((lu_byte)0)
#define HOK 0
#define HNOTFOUND 1
#define luaH_psetstr(table, key, value) HOK
#define allocsizenode(table) 0u
#define gnode(table, index) ((Node *)0)
#define keyisnil(node) 1
#define ttisnil(value) 0
#define luaH_resize(L, table, asize, hsize) ((void)0)
#define setsvalue(L, target, string) ((void)0)
#define luaH_finishset(L, table, key, value, result) ((void)0)
#define invalidateTMcache(table) ((void)0)
#define luaC_barrierback(L, object, value) ((void)0)
#define obj2gco(value) (value)
#define luaD_checkstack(L, slots) ((void)0)
]])
            for _, name in ipairs({
                "luaconf.h", "lauxlib.h", "lgc.h", "ltable.h",
                "ltm.h", "lfunc.h", "lstring.h", "lvm.h",
                "lobject.h", "ldo.h",
            }) do
                header(lua_root, name)
            end
            return runtime_root, files
        end

        local function with_synthetic_driver_profile(
                root, body, before_context)
            local driver = require "titan-compiler.driver"
            local csemantics = require "titan-compiler.csemantics"
            local original_target_profile_inputs =
                cdriver.target_profile_inputs
            local original_build_profile = csemantics.build_profile
            local old_profile = driver.TARGET_PROFILE
            local old_installed = driver.INSTALLED
            local old_include_path = driver.INCLUDE_PATH
            local old_lua_path = driver.LUA_SOURCE_PATH
            local old_runtime_path = driver.TITAN_RUNTIME_PATH
            local old_cflags = driver.CFLAGS
            local restoring = false

            cdriver.target_profile_inputs = function(options)
                if restoring then return {} end
                local synthetic = {}
                for key, value in pairs(options) do synthetic[key] = value end
                synthetic.compiler_include_dirs = { root }
                return original_target_profile_inputs(synthetic)
            end
            csemantics.build_profile = function(inputs, ...)
                if restoring then return old_profile end
                return original_build_profile(inputs, ...)
            end

            local context
            local ran, failure = xpcall(function()
                if before_context then before_context(driver) end
                context = driver.new_resolver_context()
                body(driver, context)
            end, debug.traceback)
            local closed = table.pack(true, true)
            if context then
                closed = table.pack(pcall(
                    driver.close_resolver_context, context))
            end

            driver.LUA_SOURCE_PATH = old_lua_path
            driver.TITAN_RUNTIME_PATH = old_runtime_path
            driver.INCLUDE_PATH = old_include_path
            driver.CFLAGS = old_cflags
            driver.INSTALLED = old_installed
            restoring = true
            local restored = table.pack(pcall(function()
                local restore_context = driver.new_resolver_context()
                local configured, configure_error =
                    driver.configure_foreign_c(restore_context)
                local restore_closed, close_error =
                    driver.close_resolver_context(restore_context)
                assert.truthy(configured, configure_error)
                assert.truthy(restore_closed, close_error)
            end))

            cdriver.target_profile_inputs =
                original_target_profile_inputs
            csemantics.build_profile = original_build_profile

            assert.truthy(closed[1], closed[2])
            assert.truthy(closed[2], closed[3])
            assert.truthy(restored[1], restored[2])
            assert.truthy(ran, failure)
        end

        setup(function()
            require("c-parser.cpp").clear_probe_cache()
        end)

        it("imports libuv-shaped X-macro error enumerators under flags",
        function()
            local root = tmp_dir()
            local header = root .. "/uv-shaped.h"
            write_file(header, [[
#ifdef _GNU_SOURCE
#define UV_CONFIGURED_ERROR(XX) XX(ECANCELED, -125)
#else
#define UV_CONFIGURED_ERROR(XX)
#endif
#define UV_ERRNO_MAP(XX) \
    XX(EIO, -5) \
    UV_CONFIGURED_ERROR(XX) \
    XX(EOF, -4095)
typedef enum {
#define XX(code, value) UV_ ## code = value,
    UV_ERRNO_MAP(XX)
#undef XX
} uv_errno_t;
]])
            local types = assert_process_file(header, {
                compiler = { os.getenv("CC") or "cc" },
                language_mode = "c99",
                cppflags = { "-D_GNU_SOURCE" },
                compiler_include_dirs = {},
            })

            local function enum_value(name)
                for _, item in ipairs(assert(types[name]).values) do
                    if item.name == name then
                        return item.value
                    end
                end
            end

            assert.equal("enum", assert(types.UV_EIO).type)
            local eio = assert(enum_value("UV_EIO"))
            local canceled = assert(enum_value("UV_ECANCELED"))
            -- POSIX errno numbers are target-specific; libuv's portable
            -- contract is that every error value is negative.
            assert.is_true(eio < 0)
            assert.is_true(canceled < 0)
            assert.equal(-4095, enum_value("UV_EOF"))
            assert.equal("typedef", assert(types.uv_errno_t).type)

            os.remove(header)
        end)

        it("publishes compile-flag aliases to renamed C functions", function()
            local header = tmp_header([[
typedef struct fixture_state fixture_state;
void *fixture_newuserdatauv(
    fixture_state *state, int uservalues);
]])
            local types = assert_process_file(header, {
                compiler = { os.getenv("CC") or "cc" },
                language_mode = "c99",
                language_flag = false,
                compile_flags = {
                    "--std=c99",
                    "-Dfixture_newuserdatauv=fixture_test_newuserdatauv",
                },
                cppflags = {},
                compiler_include_dirs = {},
            })

            local alias = assert(types.fixture_newuserdatauv)
            local target = assert(types.fixture_test_newuserdatauv)
            assert.equal("function", target.type)
            assert.equal("function", alias.type)
            assert.equal("fixture_newuserdatauv", alias.name)
            assert.equal(target.ret, alias.ret)
            assert.equal(target.params, alias.params)
            assert.equal(target.paramnames, alias.paramnames)
            assert.equal(target.paramnames_state, alias.paramnames_state)
            assert.equal(target.vararg, alias.vararg)

            os.remove(header)
        end)

        it("uses -I and -D flags for top-level and recursive header parsing", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "include path with spaces")
            local outer = incdir .. "/flags_only.h"
            local inner = incdir .. "/flags_nested.h"
            write_file(inner, "typedef int nested_from_flag_path;\n")
            write_file(outer, [[
#include <flags_nested.h>
#ifdef TITAN_FLAG_BRANCH
typedef int selected_by_flag;
#else
typedef double selected_by_flag;
#endif
]])

            local types, include = assert_process_file("flags_only.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", incdir, "-DTITAN_FLAG_BRANCH=1" },
            })
            assert.same({ "int" }, types.selected_by_flag.def)
            assert.same({ "int" }, types.nested_from_flag_path.def)
            assert.equal(outer, include.resolved)
            assert.equal("angle", include.include_kind)

            remove_tree({ outer, inner }, { incdir, root })
        end)

        it("resolves -iquote headers as quoted includes", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "quote includes")
            local header = incdir .. "/quote_only.h"
            write_file(header, "typedef int titan_quote_only;\n")

            local types, include = assert_process_file("quote_only.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-iquote", incdir },
            })
            assert.same({ "int" }, types.titan_quote_only.def)
            assert.equal(header, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal("quote_only.h", include.include_name)

            remove_tree({ header }, { incdir, root })
        end)

        it("searches user -I directories before Titan's fixed include dirs",
           function()
            local root = tmp_dir()
            local incdir = mkdir(root, "colliding includes")
            local titandir = mkdir(incdir, "titan")
            local header = titandir .. "/ffi.h"
            write_file(header, "typedef int titan_user_header_won;\n")

            local types, include = assert_process_file("titan/ffi.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", incdir },
            })
            assert.same({ "int" }, types.titan_user_header_won.def)
            assert.equal(header, include.resolved)
            assert.equal("angle", include.include_kind)

            remove_tree({ header }, { titandir, incdir, root })
        end)

        it("separates include and macro probes by the complete flag array", function()
            local root = tmp_dir()
            local first = mkdir(root, "first flags")
            local second = mkdir(root, "second flags")
            local first_header = first .. "/cached_config.h"
            local second_header = second .. "/cached_config.h"
            write_file(first_header, [[
#ifdef FIRST_CONFIG
typedef int cached_selection;
#else
typedef float cached_selection;
#endif
]])
            write_file(second_header, [[
#ifdef SECOND_CONFIG
typedef double cached_selection;
#else
typedef float cached_selection;
#endif
]])

            local first_types = assert_process_file("cached_config.h", {
                compiler = "cc",
                language_mode = "c99",
                cppflags = { "-I", first, "-DFIRST_CONFIG=1" },
            })
            assert.same({ "int" }, first_types.cached_selection.def)

            local second_types, include = assert_process_file("cached_config.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", second, "-DSECOND_CONFIG=1" },
            })
            assert.same({ "double" }, second_types.cached_selection.def)
            assert.equal(second_header, include.resolved)

            remove_tree({ first_header, second_header }, { first, second, root })
        end)

        it("reparses forced macro headers and publishes their exact bytes",
        function()
            local root = tmp_dir()
            local forced = root .. "/forced-macros.h"
            local imported = root .. "/imported.h"
            write_file(imported,
                "typedef TITAN_FORCED_TYPE titan_forced_value;\n")
            write_file(forced, "#define TITAN_FORCED_TYPE int\n")
            local options = {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-include", forced },
                source_dir = root,
            }

            local first, first_include =
                assert_process_file("imported.h", options)
            assert.same({ "int" }, first.titan_forced_value.def)
            assert.same({
                {
                    kind = "file",
                    path = forced,
                    identity = assert(cdriver.header_input_identity(
                        "file", forced)),
                },
                {
                    kind = "file",
                    path = imported,
                    identity = assert(cdriver.header_input_identity(
                        "file", imported)),
                },
            }, first_include.c_header_dependencies)

            write_file(forced, "#define TITAN_FORCED_TYPE long\n")
            local second, second_include =
                assert_process_file("imported.h", options)
            assert.same({ "long" }, second.titan_forced_value.def)
            assert.not_equal(
                first_include.c_header_dependencies[1].identity,
                second_include.c_header_dependencies[1].identity)

            remove_tree({ forced, imported }, { root })
        end)

        it("honors forced-header spellings and compiler ordering", function()
            local root = tmp_dir()
            local imacros_one = root .. "/imacros-one.h"
            local imacros_two = root .. "/imacros-two.h"
            local include_one = root .. "/include-one.h"
            local include_two = root .. "/include-two.h"
            local imported = root .. "/imported.h"
            write_file(imacros_one, [[
#define TITAN_FORCED_STEP 1
typedef int titan_imacros_output_must_be_hidden;
]])
            write_file(imacros_two, [[
#if TITAN_FORCED_STEP == 1
#define TITAN_FORCED_STEP 2
#else
#define TITAN_FORCED_STEP 99
#endif
]])
            write_file(include_one, [[
#if TITAN_FORCED_STEP == 2
#define TITAN_FORCED_STEP 3
#endif
]])
            write_file(include_two, [[
#if TITAN_FORCED_STEP == 3
typedef long titan_forced_order_value;
#else
typedef double titan_forced_order_value;
#endif
]])
            write_file(imported, "extern int titan_forced_order_marker;\n")

            local types, include = assert_process_file("imported.h", {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = root,
                -- Deliberately interleave both classes. GCC and Clang apply
                -- all imacros first, then all includes, stably within class.
                cppflags = {
                    "-include", include_one,
                    "-imacros" .. imacros_one,
                    "-include" .. include_two,
                    "-imacros", imacros_two,
                },
            })
            assert.same({ "long" }, types.titan_forced_order_value.def)
            assert.is_nil(types.titan_imacros_output_must_be_hidden)
            assert.same({
                imacros_one, imacros_two, include_one, include_two, imported,
            }, (function()
                local paths = {}
                for _, dependency in ipairs(
                        include.c_header_dependencies) do
                    paths[#paths + 1] = dependency.path
                end
                return paths
            end)())

            remove_tree({
                imacros_one, imacros_two, include_one, include_two, imported,
            }, { root })
        end)

        it("invalidates nested forced-header search shadowing", function()
            local root = tmp_dir()
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            local early_nested = early .. "/forced-nested.h"
            local late_nested = late .. "/forced-nested.h"
            write_file(forced, "#include <forced-nested.h>\n")
            write_file(late_nested,
                "typedef int titan_forced_nested_value;\n")
            write_file(imported, "extern int titan_forced_nested_marker;\n")
            local options = {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = root,
                compile_flags = {
                    "-I", early, "-I", late, "-include", forced,
                },
                compiler_include_dirs = {},
            }

            local first, first_include =
                assert_process_file("imported.h", options)
            assert.same({ "int" }, first.titan_forced_nested_value.def)
            assert.equal(late_nested,
                first_include.c_header_dependencies[2].path)
            local saw_missing_early = false
            for _, input in ipairs(first_include.c_header_search_inputs) do
                if input.path == early_nested then
                    saw_missing_early = true
                    assert.matches("open=unreadable", input.identity, 1, true)
                end
            end
            assert.is_true(saw_missing_early)

            write_file(early_nested,
                "typedef long titan_forced_nested_value;\n")
            local changed, changed_include =
                assert_process_file("imported.h", options)
            assert.same({ "long" }, changed.titan_forced_nested_value.def)
            assert.equal(early_nested,
                changed_include.c_header_dependencies[2].path)

            remove_tree({
                forced, imported, early_nested, late_nested,
            }, { early, late, root })
        end)

        it("retains exact forced and ordinary lookup paths",
        function()
            local root = tmp_dir()
            local child = mkdir(root, "child")
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            write_file(forced, "#define TITAN_NORMALIZED_TYPE int\n")
            write_file(imported,
                "typedef TITAN_NORMALIZED_TYPE titan_normalized_value;\n")
            local forced_lookup = child .. "/../forced.h"
            local imported_lookup = child .. "/../imported.h"
            local types, include = assert_process_file("imported.h", {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = child .. "/..",
                compile_flags = {
                    "-I", child .. "/..",
                    "-include" .. forced_lookup,
                },
                compiler_include_dirs = {},
            })
            assert.same({ "int" }, types.titan_normalized_value.def)
            assert.equal(imported_lookup, include.resolved)
            assert.same({ forced_lookup, imported_lookup }, {
                include.c_header_dependencies[1].path,
                include.c_header_dependencies[2].path,
            })
            assert.equal(forced_lookup,
                include.c_header_search_inputs[1].path)
            assert.equal(imported_lookup,
                include.c_header_search_inputs[2].path)

            remove_tree({ forced, imported }, { child, root })
        end)

        it("rejects an unreadable forced header before parsing a module",
        function()
            local root = tmp_dir()
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            write_file(forced, "#define TITAN_UNREADABLE_FORCED 1\n")
            write_file(imported, "extern int titan_unreadable_marker;\n")
            local original_open = io.open
            io.open = function(path, mode)
                if path == forced and mode == "rb" then
                    return nil, "simulated forced-header access denial"
                end
                return original_open(path, mode)
            end
            local ok, types, err = pcall(cdriver.process_file,
                "imported.h", {
                    compiler = { "cc" },
                    source_dir = root,
                    cppflags = { "-include", forced },
                })
            io.open = original_open
            assert.is_true(ok, types)
            assert.is_nil(types)
            assert.matches("missing or unreadable", err, 1, true)
            assert.matches("simulated forced%-header access denial", err)

            remove_tree({ forced, imported }, { root })
        end)

        it("separates predefined macro probes by C language mode", function()
            local header = tmp_header([[
#if __STDC_VERSION__ >= 201112L
typedef int language_selection;
#else
typedef double language_selection;
#endif
]])

            local c99_types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "double" }, c99_types.language_selection.def)

            local c11_types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c11",
                cppflags = {},
            })
            assert.same({ "int" }, c11_types.language_selection.def)

            os.remove(header)
        end)

        it("orders CPP flags before Titan's fixed language mode", function()
            local header = tmp_header([[
#if __STDC_VERSION__ >= 201112L
typedef int wrong_order_selection;
#else
typedef double fixed_mode_selection;
#endif
]])

            local types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c99",
                cppflags = { "-std=c11" },
            })
            assert.same({ "double" }, types.fixed_mode_selection.def)
            assert.is_nil(types.wrong_order_selection)

            os.remove(header)
        end)

        it("separates probes by compiler command and quotes compiler paths", function()
            local root = tmp_dir()
            local bindir = mkdir(root, "compiler path")
            local compiler = bindir .. "/titan test cc"
            local header = bindir .. "/compiler_config.h"
            local quoted_bindir = assert(cdriver.shell_quote(bindir))
            write_file(compiler, "#!/bin/sh\nexec cc -I" .. quoted_bindir
                .. " -DTITAN_WRAPPER_CC=1 \"$@\"\n")
            local quoted_compiler = assert(cdriver.shell_quote(compiler))
            local chmod_ok = os.execute("chmod +x " .. quoted_compiler)
            assert.truthy(chmod_ok)
            write_file(header, [[
#ifdef TITAN_WRAPPER_CC
typedef int compiler_selection;
#else
typedef double compiler_selection;
#endif
]])

            local wrapped, include = assert_process_file("compiler_config.h", {
                compiler = quoted_compiler,
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "int" }, wrapped.compiler_selection.def)
            assert.equal(header, include.resolved)

            local plain = assert_process_file(header, {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "double" }, plain.compiler_selection.def)

            remove_tree({ header, compiler }, { bindir, root })
        end)

        it("preserves the compiler's CPATH include search", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "cpath includes")
            local header = incdir .. "/cpath_only.h"
            write_file(header, "typedef int found_through_cpath;\n")

            local types, include = assert_process_file("cpath_only.h", {
                compiler = { "env", "CPATH=" .. incdir, "cc" },
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "int" }, types.found_through_cpath.def)
            assert.equal(header, include.resolved)

            remove_tree({ header }, { incdir, root })
        end)

        it("refreshes fixed FFI includes after the driver Lua path changes",
           function()
            local lua_root, lua_header = synthetic_profile_root()
            local runtime_root, files = synthetic_preamble_roots(lua_root)
            local alternate = lua_root .. "/alternate_lua_path.h"
            files[#files + 1] = lua_header
            files[#files + 1] = alternate
            write_file(alternate,
                "typedef int alternate_lua_path_marker;\n")

            local ok, err = xpcall(function()
                with_synthetic_driver_profile(lua_root,
                    function(driver, context)
                        local checker = require "titan-compiler.checker"
                        local parser = require "titan-compiler.parser"
                        driver.INCLUDE_PATH = runtime_root
                        local configured, configure_error =
                            driver.configure_foreign_c(context)
                        assert.truthy(configured, configure_error)
                        local expected_include_dirs = {
                            runtime_root,
                            lua_root,
                        }
                        if not driver.INSTALLED then
                            expected_include_dirs[#expected_include_dirs + 1] =
                                driver.LIBBACKTRACE_PATH
                        end
                        assert.same(expected_include_dirs,
                            driver.foreign_include_dirs())

                        local code = [[
                            local alt = foreign import "alternate_lua_path.h"
                            function size(): integer
                                return alt.alternate_lua_path_marker.sizeof
                                    as integer
                            end
                        ]]
                        local ast = assert(
                            parser.parse("alternate.titan", code))
                        local _, errors = checker.check(
                            "alternate", ast, code, "alternate.titan", nil, {
                                probe_service_provider = function()
                                    return driver.get_probe_service(context)
                                end,
                            })
                        assert.equal(0, #errors,
                            table.concat(errors, "\n"))
                    end,
                    function(driver)
                        driver.TITAN_RUNTIME_PATH = runtime_root
                        driver.LUA_SOURCE_PATH = lua_root
                    end)
            end, debug.traceback)
            remove_tree(files, { runtime_root, lua_root })
            assert.truthy(ok, err)
        end)

        it("acquires Lua numeric spellings and target macros under exact flags",
           function()
            local root, header = synthetic_profile_root()
            local ok, err = xpcall(function()
                local inputs = assert(cdriver.target_profile_inputs({
                    compiler = { os.getenv("CC") or "cc" },
                    language_mode = "c99",
                    language_flag = false,
                    compile_flags = {
                        "--std=c99",
                        "-funsigned-char",
                        "-DTITAN_PROFILE_FLAG=23",
                    },
                    cppflags = {},
                    compiler_include_dirs = { root },
                }))

                assert.equal("long long", inputs.lua_integer)
                assert.equal("double", inputs.lua_number)
                assert.is_string(inputs.size_t)
                assert.is_string(inputs.ptrdiff_t)
                assert.is_table(inputs.signed_minima)
                for _, spelling in ipairs({
                    "signed char", "short", "int", "long", "long long",
                }) do
                    assert.is_table(inputs.signed_minima[spelling])
                end
                assert.same({ "1" }, inputs.macros.__CHAR_UNSIGNED__)
                assert.same({ "23" }, inputs.macros.TITAN_PROFILE_FLAG)
                assert.same({ root }, inputs.fixed_include_dirs)
                assert.equal("lua.h", inputs.lua_header.original)
                assert.equal(header, inputs.lua_header.resolved)
                local profile = assert(require(
                    "titan-compiler.csemantics").build_profile(inputs))
                assert.is_false(
                    profile.integers[profile.size_t].type.signed)
                assert.is_true(
                    profile.integers[profile.ptrdiff_t].type.signed)
            end, debug.traceback)
            remove_tree({ header }, { root })
            assert.truthy(ok, err)
        end)

        it("rebuilds profiles and resolver probe services after reconfiguration",
           function()
            local root, header = synthetic_profile_root()
            local ok, err = xpcall(function()
                with_synthetic_driver_profile(root,
                    function(driver, context)
                        local first = assert(
                            driver.get_probe_service(context))
                        local first_configuration =
                            driver.FOREIGN_C_CONFIGURATION_ID
                        driver.CFLAGS =
                            driver.CFLAGS .. " -funsigned-char"
                        local configured, configure_error =
                            driver.configure_foreign_c(context)
                        assert.truthy(configured, configure_error)
                        assert.is_true(
                            driver.FOREIGN_C_CONFIGURATION_ID >
                            first_configuration)
                        assert.is_false(driver.TARGET_PROFILE.char_signed)

                        local second = assert(
                            driver.get_probe_service(context))
                        assert.not_equal(first, second)
                        assert.is_true(first.closed)
                        assert.equal(driver.TARGET_PROFILE.identity,
                            second.profile_identity)
                    end)
            end, debug.traceback)
            remove_tree({ header }, { root })
            assert.truthy(ok, err)
        end)

        it("rejects unparsed or malformed configuration", function()
            local header = tmp_header("typedef int never_reached;\n")

            local types, err = cdriver.process_file(header, {
                cppflags = "-I/tmp/include",
            })
            assert.is_nil(types)
            assert.matches("cppflags must be a parsed argument array", err)

            types, err = cdriver.process_file(header, {
                compiler = "cc 'unfinished",
                cppflags = {},
            })
            assert.is_nil(types)
            assert.matches("unterminated single quote", err)

            types, err = cdriver.process_file(header, {
                compiler = "cc",
                language_mode = "c99; touch /tmp/nope",
                cppflags = {},
            })
            assert.is_nil(types)
            assert.matches("invalid C language mode", err)

            os.remove(header)
        end)
    end)
end)

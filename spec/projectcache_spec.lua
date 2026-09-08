local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local parser = require "titan-compiler.parser"
local lfs = require "lfs"
local sha256 = require "titan-compiler.sha256"

describe("checked project payloads", function()
    local previous_imported, previous_registry, loaders
    before_each(function()
        previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry, loaders = {}, {}, {}
    end)
    after_each(function()
        for _, loader in ipairs(loaders) do driver.close_loader(loader) end
        driver.imported, types.registry = previous_imported, previous_registry
    end)

    local function load_module(name, source, retained, extra_options)
        local filename = "/tmp/titan-project-cache-" .. name .. ".titan"
        local options = {
            source_roots = { [name] = true },
            source_overrides = { [name] = {
                kind = "generated", main = filename, files = { filename },
                contents = { [filename] = source },
            } },
            cached_source_entries = retained,
        }
        for key, value in pairs(extra_options or {}) do options[key] = value end
        local loader = driver.defaultloader({}, options)
        loaders[#loaders + 1] = loader
        local ok, result, errors = loader(name)
        assert.is_true(ok, result)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return driver.imported[name]
    end

    it("hydrates a private generic source entry and reuses it on the next edit", function()
        local provider = load_module("provider", [[
            record Box<A> item: A end
            local function secret<A>(item: A): A return item end
        ]])
        local payload = assert(driver.encode_project_entry(provider))
        driver.imported, types.registry = {}, {}
        local restored = assert(driver.decode_project_entry(payload, {
            module_name = "provider",
            project_files = { [provider.filename] = true },
        }))
        assert.not_equal(provider.ast, restored.ast)
        assert.equal(restored.ast[1], restored.ast[1]._decl)
        local declared = assert(driver.project_entries_registry({ provider = restored }))
        assert.equal(restored.ast._declared_registry["provider.Box"],
            declared["provider.Box"])
        assert.equal(1, #declared["provider.Box"].typeparams)
        types.registry = declared
        local original_parse, parsed = parser.parse, {}
        parser.parse = function(filename, source)
            parsed[#parsed + 1] = filename
            return original_parse(filename, source)
        end
        local ok, consumer = pcall(load_module, "consumer", [[
            local provider = import "provider.titan"
            function answer(): integer
                local box = provider.Box<integer>.new(42)
                return provider.secret<integer>(box.item)
            end
        ]], { provider = restored })
        parser.parse = original_parse
        assert.is_true(ok, consumer)
        assert.same({ consumer.filename }, parsed)
        assert.equal(restored, driver.imported.provider)
        assert.is_true(consumer.ast[1]._source_import)
    end)

    it("rejects external ASTs through otherwise retained type annotations", function()
        local entry = load_module("project", "function answer(): integer return 42 end")
        local external = assert(parser.parse("/outside/external.titan",
            "function external(): integer return 1 end"))
        entry.ast[1]._external_navigation = external[1]
        local payload, err = driver.encode_project_entry(entry)
        assert.is_nil(payload)
        assert.matches("external source AST", err, 1, true)
    end)

    it("forwards checksum callbacks without swallowing cancellation objects", function()
        local entry = load_module("checksums", "function answer(): integer return 42 end")
        local calls = 0
        local options = { sha256_binary = function(bytes)
            calls = calls + 1
            return sha256.binary(bytes)
        end }
        local payload = assert(driver.encode_project_entry(entry, options))
        assert.equal(1, calls)
        assert(driver.decode_project_entry(payload))
        assert(driver.decode_project_entry(payload, options))
        assert.equal(2, calls)
        local cancelled = {}
        options.sha256_binary = function() error(cancelled, 0) end
        local ok, err = pcall(driver.encode_project_entry, entry, options)
        assert.is_false(ok)
        assert.equal(cancelled, err)
        ok, err = pcall(driver.decode_project_entry, payload, options)
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)

    it("overlays matching current header observations throughout a private graph", function()
        local entry = load_module("observations", "function answer(): integer return 42 end")
        local old = { modified_seconds = 100, modified_nanoseconds = 5, physical_identity = "physical" }
        local input = { kind = "file", path = "/observed.h", identity = "semantic", observation = old }
        entry.c_header_dependencies = { input }
        entry.ast._c_header_dependencies = { input }
        entry.ast[1]._nested_header_input = {
            kind = input.kind, path = input.path, identity = input.identity, observation = old,
        }
        entry.ast[1]._unmatched_header_input = {
            kind = input.kind, path = input.path, identity = "other semantic", observation = old,
        }
        local payload = assert(driver.encode_project_entry(entry))
        local current = { modified_seconds = 100, modified_nanoseconds = 6, physical_identity = "physical" }
        local restored = assert(driver.decode_project_entry(payload, { header_inputs = {
            { kind = input.kind, path = input.path, identity = input.identity, observation = current },
        } }))
        assert.same(current, restored.c_header_dependencies[1].observation)
        assert.same(current, restored.ast[1]._nested_header_input.observation)
        assert.same(old, restored.ast[1]._unmatched_header_input.observation)
        assert.same(old, entry.c_header_dependencies[1].observation)
        assert.equal(assert(driver.serialize_source_interface(entry)),
            assert(driver.serialize_source_interface(restored)))
        assert.same(old, assert(driver.decode_project_entry(payload)).c_header_dependencies[1].observation)
    end)

    it("cooperates during declared-registry validation and propagates cancellation", function()
        local entry = load_module("registry_yield", "function answer(): integer return 42 end")
        entry.ast[1]._large_annotation = {}
        for index = 1, 20000 do entry.ast[1]._large_annotation[index] = index end
        local calls, cancellation = 0, {}
        local ok, err = pcall(driver.project_entries_registry, { registry_yield = entry }, {
            yield = function()
                calls = calls + 1
                if calls == 2 then error(cancellation, 0) end
            end,
        })
        assert.is_false(ok)
        assert.equal(2, calls)
        assert.equal(cancellation, err)
    end)

    it("shares the cooperative work budget across many small registry entries", function()
        local entries = {}
        for index = 1, 100 do
            local name = "small_entry_" .. index
            local annotation = {}
            for item = 1, 100 do annotation[item] = { value = item } end
            entries[name] = {
                kind = "source", filename = name .. ".titan", source_files = { name .. ".titan" },
                deps = {}, source_manifest = "source", ast = { _declared_registry = {}, annotation = annotation },
                type = { _tag = "Type.Module", name = name, _source = true,
                    source_members = {}, source_type_members = {} },
            }
        end
        local calls = 0
        assert(driver.project_entries_registry(entries, { yield = function() calls = calls + 1 end }))
        assert.is_true(calls > 1)
        local cancellation = {}
        local ok, err = pcall(driver.project_entries_registry, entries,
            { yield = function() error(cancellation, 0) end })
        assert.is_false(ok)
        assert.equal(cancellation, err)
    end)

    it("uses fresh observation baselines for later edits with retained source-import graphs", function()
        local compiler_io = require "titan-compiler.io"
        local strategy = compiler_io.new_sync()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "wb"))
        assert(file:write("typedef int retained_count;\n"))
        assert(file:close())
        local reads, ordinary_read = 0, strategy.read_file
        function strategy:read_file(path)
            if path == header then reads = reads + 1 end
            return ordinary_read(self, path)
        end
        local ok, err = pcall(function()
            local provider = load_module("baseline_provider", string.format([[
                local c = foreign import %q
                foreign function identity(input: c.retained_count): c.retained_count return input end
            ]], header), nil, { io = strategy })
            local old_stamp = provider.c_header_dependencies[1].observation.modified_seconds
            local stamp = assert(lfs.attributes(header, "modification"))
            assert(lfs.touch(header, stamp + 1, stamp + 1))
            local current, restat_error, changed = driver.restat_c_header_dependencies(
                provider.c_header_dependencies, { io = strategy })
            assert(current, restat_error)
            assert.is_false(changed)
            reads = 0
            for index = 1, 2 do
                driver.imported, types.registry = {}, {}
                load_module("baseline_consumer", string.format([[
                    local provider = import "baseline_provider.titan"
                    function answer(): integer
                        local current = provider.identity(%d)
                        return 42
                    end
                ]], index), { baseline_provider = provider }, {
                    io = strategy, header_inputs = current,
                })
                assert.equal(0, reads)
            end
            assert.equal(old_stamp, provider.c_header_dependencies[1].observation.modified_seconds)
        end)
        os.remove(header)
        assert.is_true(ok, err)
    end)

    it("recreates source-private checking headers after decoding a closed resolver", function()
        local provider = load_module("provider", [[
            local c = foreign import "stdint.h"
            foreign function identity(input: c.int32_t): c.int32_t return input end
        ]])
        local original_header = assert(provider.checking_foreign_header)
        assert.equal("file", lfs.attributes(original_header, "mode"))
        local payload = assert(driver.encode_project_entry(provider))
        assert.is_true(driver.close_loader(loaders[1]))
        assert.is_nil(lfs.attributes(original_header))
        driver.imported, types.registry = {}, {}
        local restored = assert(driver.decode_project_entry(payload, { module_name = "provider" }))
        assert.is_nil(restored.checking_foreign_header)
        local consumer = load_module("consumer", [[
            local provider = import "provider.titan"
            function answer(): integer
                local current = provider.identity(42)
                return 42
            end
        ]], { provider = restored })
        local fresh = assert(restored.checking_foreign_header)
        assert.not_equal(original_header, fresh)
        assert.equal("file", lfs.attributes(fresh, "mode"))
        assert.equal(fresh, consumer.ast[1]._foreign_header)
    end)

    it("rejects wrong module/file ownership and corrupt payloads without global changes", function()
        local entry = load_module("project", "function answer(): integer return 42 end")
        local payload = assert(driver.encode_project_entry(entry))
        local imported, registry = driver.imported, types.registry
        assert.is_nil(driver.decode_project_entry(payload, { module_name = "other" }))
        assert.is_nil(driver.decode_project_entry(payload, { project_files = {} }))
        assert.is_nil(driver.decode_project_entry(payload:sub(1, -2)))
        assert.equal(imported, driver.imported)
        assert.equal(registry, types.registry)
        assert.is_nil(driver.encode_project_entry({ kind = "source", ast = {} }))
    end)
end)

describe("language-server compiler cache identity", function()
    it("is stable across resolvers and includes ordered live C include roots", function()
        local first = driver.new_resolver_context()
        local second = driver.new_resolver_context()
        local changed = driver.new_resolver_context({ extra_ffi_include_dirs = { "/tmp" } })
        local ok, err = pcall(function()
            local identity = assert(driver.language_server_cache_identity({ context = first }))
            assert.equal(identity, driver.language_server_cache_identity({ context = second }))
            assert.not_equal(identity, driver.language_server_cache_identity({ context = changed }))
        end)
        driver.close_resolver_context(first)
        driver.close_resolver_context(second)
        driver.close_resolver_context(changed)
        assert.is_true(ok, err)
    end)

    it("keeps native-unavailable identity independent of probe diagnostic temporaries", function()
        local context = driver.new_resolver_context()
        local profile = assert(driver.get_target_profile(context))
        local old_target, old_probe, old_cc = driver.get_target_profile,
            driver.get_probe_service, driver.CC
        local calls = 0
        local ok, err = pcall(function()
            driver.get_target_profile = function() return profile end
            driver.get_probe_service = function()
                calls = calls + 1
                return nil, "probe failed at /tmp/unique-probe-" .. calls
            end
            local identity = assert(driver.language_server_cache_identity({ context = context }))
            assert.equal(identity, driver.language_server_cache_identity({ context = context }))
            driver.CC = "different-unavailable-cc"
            assert.not_equal(identity, driver.language_server_cache_identity({ context = context }))
        end)
        driver.get_target_profile, driver.get_probe_service, driver.CC = old_target, old_probe, old_cc
        driver.close_resolver_context(context)
        assert.is_true(ok, err)
    end)
end)

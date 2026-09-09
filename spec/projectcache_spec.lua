local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local parser = require "titan-compiler.parser"
local lfs = require "lfs"
local sha256 = require "titan-compiler.sha256"
local cpp = require "c-parser.cpp"

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

    it("transports deep cyclic annotations and CPP provenance while yielding", function()
        local entry = load_module("graph_annotations", "function answer(): integer return 42 end")
        local context = assert(cpp.new_context())
        assert(cpp.parse_contents("/macro-sidecars.h", [[
#define STRINGIFY(x) #x
#define VALUE STRINGIFY(a + b)
]], context))
        local root = { macros = context.defines }
        local tail = root
        for _ = 1, 6000 do
            tail.next = {}
            tail = tail.next
        end
        tail.parent, root[tail] = root, tail
        root.alias = tail
        root.weak = setmetatable({ [tail] = root }, { __mode = "k" })
        local external_key = { label = "owned outside the entry" }
        root.weak_only = setmetatable({ [external_key] = "preserved" }, { __mode = "k" })
        entry.ast._annotations = root
        local calls = 0
        local payload = assert(driver.encode_project_entry(entry, {
            yield = function()
                calls = calls + 1
                assert.equal("owned outside the entry", external_key.label)
                collectgarbage("collect")
            end,
        }))
        assert.is_true(calls > 4)
        local copy = assert(driver.decode_project_entry(payload)).ast._annotations
        local retained_key = next(copy.weak_only)
        assert.is_not_nil(retained_key)
        assert.equal("owned outside the entry", retained_key.label)
        assert.equal("preserved", copy.weak_only[retained_key])
        local last = copy
        for _ = 1, 6000 do last = last.next end
        assert.equal(copy, last.parent)
        assert.equal(last, copy[last])
        assert.equal(last, copy.alias)
        assert.equal(copy, copy.weak[last])
        assert.equal("k", getmetatable(copy.weak).__mode)
        assert.equal('"a + b"', cpp.expand_macro("VALUE", copy.macros))
        assert.equal('"a + b"', cpp.expand_macro("VALUE", root.macros))
        local cancellation = {}
        calls = 0
        local ok, err = pcall(driver.encode_project_entry, entry, {
            yield = function()
                calls = calls + 1
                if calls == 2 then error(cancellation, 0) end
            end,
        })
        assert.is_false(ok)
        assert.equal(2, calls)
        assert.equal(cancellation, err)
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

    it("assembles empty modules without a declared owner registry", function()
        local entry = load_module("empty_registry", "")
        entry.ast._declared_registry = nil
        local restored = assert(driver.decode_project_entry(assert(driver.encode_project_entry(entry))))
        assert.same({}, driver.project_entries_registry({ empty_registry = restored }))
    end)

    it("cooperates during large declared-registry assembly and propagates cancellation", function()
        local entry = load_module("registry_yield", "function answer(): integer return 42 end")
        for index = 1, 20000 do
            local name = "registry_yield.Item" .. index
            entry.ast._declared_registry[name] = { _tag = "Type.Record", name = name }
        end
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
            local declared = {}
            for item = 1, 100 do
                local fqtn = name .. ".Item" .. item
                declared[fqtn] = { _tag = "Type.Record", name = fqtn }
            end
            entries[name] = {
                kind = "source", filename = name .. ".titan", source_files = { name .. ".titan" },
                deps = {}, source_manifest = "source", ast = { _declared_registry = declared },
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
        local artifacts = {}
        local adapter = {
            get = function(kind, key)
                local artifact = artifacts[kind .. ":" .. key]
                if artifact then return artifact.payload, artifact.inputs end
            end,
            put = function(kind, key, payload, inputs)
                artifacts[kind .. ":" .. key] = { payload = payload, inputs = inputs }
                return true
            end,
        }
        local function consumer_source(value)
            return string.format([[
                local provider = import "baseline_provider.titan"
                function answer(): integer
                    local current = provider.identity(%d)
                    return 42
                end
            ]], value)
        end
        local ok, err = pcall(function()
            local provider = load_module("baseline_provider", string.format([[
                foreign import %q
                foreign function identity(input: ffi.retained_count): ffi.retained_count return input end
            ]], header), nil, { io = strategy, cache_adapter = adapter })
            -- The consumer now preprocesses its inherited C environment too.
            -- Prime that stable header graph before measuring later edits.
            load_module("baseline_consumer", consumer_source(0),
                { baseline_provider = provider }, { io = strategy, cache_adapter = adapter })
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
                load_module("baseline_consumer", consumer_source(index), { baseline_provider = provider }, {
                    io = strategy, header_inputs = current, cache_adapter = adapter,
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
            foreign import "stdint.h"
            foreign function identity(input: ffi.int32_t): ffi.int32_t return input end
        ]])
        local original_header = assert(provider.checking_foreign_header)
        local original_ffi = assert(provider.checking_ffi_header)
        local original_bundle = assert(provider.ast._ffi_header.bundle_root)
        assert.equal("file", lfs.attributes(original_header, "mode"))
        assert.equal("file", lfs.attributes(original_ffi, "mode"))
        local payload = assert(driver.encode_project_entry(provider))
        assert.is_nil(payload:find(original_header, 1, true))
        assert.is_nil(payload:find(original_bundle, 1, true))
        assert.equal(original_bundle, provider.ast._ffi_header.bundle_root)
        assert.is_true(driver.close_loader(loaders[1]))
        assert.is_nil(lfs.attributes(original_header))
        assert.is_nil(lfs.attributes(original_ffi))
        driver.imported, types.registry = {}, {}
        local restored = assert(driver.decode_project_entry(payload, { module_name = "provider" }))
        assert.is_nil(restored.checking_foreign_header)
        assert.is_nil(restored.checking_ffi_header)
        assert.is_nil(restored.ast._ffi_header.filename)
        assert.is_nil(restored.ast._ffi_header.bundle_root)
        assert.equal("provider.ffi.h", restored.ast._ffi_header.logical_name)
        assert.equal(restored.ast._ffi_header,
            restored.ast._ffi_namespace._include.generated_header)
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
        assert.equal(restored.checking_ffi_header, consumer.ast[1]._ffi_header)
        assert.equal("file", lfs.attributes(restored.checking_ffi_header, "mode"))
    end)

    it("replays inherited C type origins after all project resolver headers close", function()
        local provider = load_module("provider", [[
            foreign import "stdint.h"
            foreign function identity(input: ffi.int32_t): ffi.int32_t return input end
        ]])
        local consumer = load_module("consumer", [[
            local provider = import "provider.titan"
            foreign function identity(input: ffi.int32_t): ffi.int32_t
                return provider.identity(input)
            end
        ]], { provider = provider })
        local options = { project_files = {
            [provider.filename] = true, [consumer.filename] = true,
        } }
        local payloads = {
            provider = assert(driver.encode_project_entry(provider, options)),
            consumer = assert(driver.encode_project_entry(consumer, options)),
        }
        local original_bundles = {
            provider.ast._ffi_header.bundle_root, consumer.ast._ffi_header.bundle_root,
        }
        for _, payload in pairs(payloads) do
            for _, bundle in ipairs(original_bundles) do
                assert.is_nil(payload:find(bundle, 1, true))
            end
        end
        for _, loader in ipairs(loaders) do assert.is_true(driver.close_loader(loader)) end
        driver.imported, types.registry = {}, {}
        local retained = {
            provider = assert(driver.decode_project_entry(payloads.provider, options)),
            consumer = assert(driver.decode_project_entry(payloads.consumer, options)),
        }
        local plan = retained.consumer.ast._ffi_header
        assert.equal("consumer.ffi.h", plan.logical_name)
        assert.equal("provider.ffi.h", plan.dependencies[1].logical_name)
        assert.equal(retained.consumer.ast[1]._ffi_header_descriptor, plan.dependencies[1])
        local original_parse, parsed = parser.parse, {}
        parser.parse = function(filename, source)
            parsed[#parsed + 1] = filename
            return original_parse(filename, source)
        end
        local ok, result = pcall(load_module, "after_restart", [[
            local consumer = import "consumer.titan"
            function answer(): integer
                local result: ffi.int32_t = consumer.identity(42)
                return 42
            end
        ]], retained)
        parser.parse = original_parse
        assert.is_true(ok, result)
        assert.same({ result.filename }, parsed)
        assert.equal(retained.consumer, driver.imported.consumer)
        assert.equal(retained.provider, driver.imported.provider)
        assert.equal(retained.provider.ast._ffi_header.digest,
            retained.consumer.ast._ffi_header.dependencies[1].digest)
    end)

    it("rejects incompatible project graph and ABI envelopes", function()
        local entry = load_module("durable", [[
            foreign import "stdint.h"
            foreign function identity(input: ffi.int32_t): ffi.int32_t return input end
        ]])
        local payload = assert(driver.encode_project_entry(entry))
        local imported, registry = driver.imported, types.registry
        local mutations = {
            function(root) root.abi = root.abi + 1 end,
            function(root) root.graph_version = root.graph_version + 1 end,
            function(root) root.kind = "another-graph-owner" end,
            function(root) root.version = 1 end,
        }
        for _, mutate in ipairs(mutations) do
            local envelope = assert(cpp.decode_graph(payload))
            mutate(envelope)
            assert.is_nil(driver.decode_project_entry(assert(cpp.encode_graph(envelope))))
            assert.equal(imported, driver.imported)
            assert.equal(registry, types.registry)
        end
    end)

    it("rejects corrupt payloads without changing compiler globals", function()
        local entry = load_module("project", "function answer(): integer return 42 end")
        local payload = assert(driver.encode_project_entry(entry))
        local imported, registry = driver.imported, types.registry
        assert.is_nil(driver.decode_project_entry(payload:sub(1, -2)))
        assert.equal(imported, driver.imported)
        assert.equal(registry, types.registry)
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

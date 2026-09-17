local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local parser = require "titan-compiler.parser"
local lfs = require "lfs"
local sha256 = require "titan-compiler.sha256"
local cpp = require "c-parser.cpp"
local coder = require "titan-compiler.coder"

describe("declared project manifests", function()
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
            analysis_only = true,
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

    local function assert_declarations_only(root)
        local seen, queue = {}, { root }
        local index = 1
        while queue[index] do
            local node = queue[index]
            if not seen[node] then
                seen[node] = true
                assert.is_nil(getmetatable(node))
                assert.is_false(type(node._tag) == "string" and node._tag:match("^Ast%.") ~= nil)
                for key, value in pairs(node) do
                    assert.is_not_equal("_decl", key)
                    assert.is_not_equal("_parameter_decls", key)
                    if type(key) == "table" then queue[#queue + 1] = key end
                    if type(value) == "table" then queue[#queue + 1] = value end
                end
            end
            index = index + 1
        end
    end

    it("hydrates a private generic source entry and reuses it on the next edit", function()
        local provider = load_module("provider", [[
            record Box<|A|> item: A end
            local function secret<|A|>(item: A): A return item end
        ]])
        local payload = assert(driver.encode_project_entry(provider))
        driver.imported, types.registry = {}, {}
        local restored = assert(driver.decode_project_entry(payload, {
            module_name = "provider",
            project_files = { [provider.filename] = true },
        }))
        assert.is_nil(restored.ast)
        assert_declarations_only(restored)
        local declared = assert(driver.project_entries_registry({ provider = restored }))
        assert.equal(restored.declared_registry["provider.Box"],
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
                local box = provider.Box<|integer|>.new(42)
                return provider.secret<|integer|>(box.item)
            end
        ]], { provider = restored })
        parser.parse = original_parse
        assert.is_true(ok, consumer)
        assert.same({ consumer.filename }, parsed)
        assert.equal(restored, driver.imported.provider)
        assert.is_true(consumer.ast[1]._source_import)
    end)

    it("restores generic constraints, alias chains, local members and named parameters", function()
        local provider = load_module("generic_surface", [[
            interface Show<|A|> function render(item: A): string end
            record Printer prefix: string end
            function Printer:render(item: integer): string return self.prefix end
            record Box<|T|> local hidden: T shown: T end
            local function Box.make(item: T): Box<|T|> return Box<|T|>.new(item, item) end
            local function Box:replace<|V|>(item: V): Box<|V|> return Box<|V|>.new(item, item) end
            local union Choice<|T|> local hidden(T) shown(T) end
            type Alias = Box
            local type PrivateAlias = Alias
            local function display<|S: Show<|integer|>|>(subject: S): string return subject:render(1) end
        ]])
        local restored = assert(driver.decode_project_entry(assert(driver.encode_project_entry(provider))))
        assert_declarations_only(restored)
        driver.imported, types.registry = {}, driver.project_entries_registry({ generic_surface = restored })
        local parsed, parse = {}, parser.parse
        parser.parse = function(filename, source)
            parsed[#parsed + 1] = filename
            return parse(filename, source)
        end
        local ok, consumer = pcall(load_module, "generic_surface_consumer", [[
            local provider = import "generic_surface.titan"
            function answer(): string
                local box = provider.PrivateAlias<|integer|>.make { item = 42 }
                local copy = box:replace<|string|> { item = "kept" }
                copy.hidden = copy.shown
                local choice = provider.Choice<|string|>.hidden(copy.hidden)
                case choice
                when hidden(item) then
                    return provider.display<|provider.Printer|> { subject = provider.Printer.new(item) }
                when shown(item) then return item
                end
            end
        ]], { generic_surface = restored })
        parser.parse = parse
        assert.is_true(ok, consumer)
        assert.same({ consumer.filename }, parsed)
        assert.equal(restored, driver.imported.generic_surface)
        local bad_ok, bad = pcall(load_module, "generic_constraint_failure", [[
            local provider = import "generic_surface.titan"
            function answer(): string return provider.display<|integer|>(42) end
        ]], { generic_surface = restored })
        assert.is_false(bad_ok)
        assert.match("does not satisfy constraint 'generic_surface.Show<|integer|>'", tostring(bad), 1, true)
    end)

    it("keeps public and source aliases distinct after hydration in either import order", function()
        local provider = load_module("alias_authority", [[
            local function hidden(): integer return 40 end
            function visible(): integer return 2 end
        ]])
        local payload = assert(driver.encode_project_entry(provider))
        for _, imports in ipairs({
            'local public = import "alias_authority"\nlocal source = import "alias_authority.titan"',
            'local source = import "alias_authority.titan"\nlocal public = import "alias_authority"',
        }) do
            local restored = assert(driver.decode_project_entry(payload))
            driver.imported, types.registry = {}, driver.project_entries_registry({ alias_authority = restored })
            local ok, err = pcall(load_module, "alias_authority_consumer", imports .. [[
                function answer(): integer return source.hidden() + public.visible() + public.hidden() end
            ]], { alias_authority = restored })
            assert.is_false(ok)
            local _, count = tostring(err):gsub("member 'hidden' not found", "")
            assert.equal(1, count, tostring(err))
        end
    end)

    it("preserves initializer visibility frontiers with compact owner and facade entries", function()
        local owner = load_module("frontier_owner", [[
            record Box end
            local function Box.secret(): integer return 42 end
        ]])
        local owner_manifest = assert(driver.compact_project_entry(owner))
        local facade = load_module("frontier_facade", [[
            local owner = import "frontier_owner"
            type Box = owner.Box
        ]], { frontier_owner = owner_manifest })
        local entries = {
            frontier_owner = assert(driver.decode_project_entry(assert(driver.encode_project_entry(owner)))),
            frontier_facade = assert(driver.decode_project_entry(assert(driver.encode_project_entry(facade)))),
        }
        driver.imported, types.registry = {}, driver.project_entries_registry(entries)
        local ok, err = pcall(load_module, "frontier_consumer", [[
            local facade = import "frontier_facade"
            local before: integer = facade.Box.secret()
            local function body_declared_before_owner_import(): integer return facade.Box.secret() end
            local owner = import "frontier_owner.titan"
            local after: integer = facade.Box.secret()
        ]], entries)
        assert.is_false(ok)
        local _, count = tostring(err):gsub("record function 'frontier_owner.Box.secret' is local", "")
        assert.equal(1, count, tostring(err))
        assert_declarations_only(entries.frontier_owner)
        assert_declarations_only(entries.frontier_facade)
    end)

    it("does not grant local nominal access through a restored source facade", function()
        local owner = load_module("private_owner", [[
            local record Secret payload: integer end
            local function make(): Secret return Secret.new(42) end
        ]])
        local facade = load_module("private_facade", [[
            local owner = import "private_owner.titan"
            local type Secret = owner.Secret
            local function make(): Secret return owner.make() end
        ]], { private_owner = assert(driver.compact_project_entry(owner)) })
        local owner_payload, facade_payload = assert(driver.encode_project_entry(owner)),
            assert(driver.encode_project_entry(facade))
        for _, direct in ipairs({ false, true }) do
            local entries = {
                private_owner = assert(driver.decode_project_entry(owner_payload)),
                private_facade = assert(driver.decode_project_entry(facade_payload)),
            }
            driver.imported, types.registry = {}, driver.project_entries_registry(entries)
            assert.equal(entries.private_owner.declared_registry["private_owner.Secret"],
                types.registry["private_owner.Secret"])
            local prefix = 'local facade = import "private_facade.titan"\n'
            if direct then prefix = prefix .. 'local owner = import "private_owner.titan"\n' end
            local ok, result = pcall(load_module, "private_nominal_consumer", prefix .. [[
                function answer(): integer return facade.make().payload end
            ]], entries)
            if direct then assert.is_true(ok, result)
            else
                assert.is_false(ok)
                assert.match("record type 'private_owner.Secret' is local to module 'private_owner'",
                    tostring(result), 1, true)
            end
        end
    end)

    it("projects deep recursive declaration graphs cooperatively without the Lua stack", function()
        local entry = load_module("deep_declaration", "function answer(): integer return 42 end")
        local first = types.Array(types.Integer(), false)
        local tail = first
        for _ = 1, 6000 do
            tail.elem = types.Array(types.Integer(), false)
            tail = tail.elem
        end
        tail.elem = first
        entry.type.members.answer.type.rettypes[1] = first
        local calls = 0
        local payload = assert(driver.encode_project_entry(entry, { yield = function()
            calls = calls + 1
            if calls % 20 == 0 then collectgarbage("collect") end
        end }))
        assert.is_true(calls > 20)
        local restored = assert(driver.decode_project_entry(payload))
        local cursor = restored.type.members.answer.type.rettypes[1]
        for _ = 1, 6001 do cursor = cursor.elem end
        assert.equal(restored.type.members.answer.type.rettypes[1], cursor)
        local cancelled = {}
        local ok, err = pcall(driver.decode_project_entry, payload, { yield = function() error(cancelled, 0) end })
        assert.is_false(ok)
        assert.equal(cancelled, err)
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

    it("drops source and CPP back-edges while preserving recursive declared types", function()
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
        entry.type.members.answer._decl = entry.ast[1]
        entry.type.members.answer._parameter_decls = { entry.ast[1] }
        entry.type.members.answer.type._annotations = root
        local calls = 0
        local payload = assert(driver.encode_project_entry(entry, { yield = function()
            calls = calls + 1
            assert.equal("owned outside the entry", external_key.label)
            collectgarbage("collect")
        end }))
        assert.is_true(calls > 0)
        local copy = assert(driver.decode_project_entry(payload))
        assert.is_nil(copy.ast)
        assert.is_nil(copy.type.members.answer._decl)
        assert.is_nil(copy.type.members.answer._parameter_decls)
        assert.is_nil(copy.type.members.answer.type._annotations)
        assert.is_nil(payload:find("owned outside the entry", 1, true))
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
        assert.is_nil(restored.ast)
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
                foreign function identity(input: retained_count): retained_count return input end
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

    it("restores only the C declaration environment after a native resolver closes", function()
        local provider = load_module("provider", [[
            foreign import "stdint.h"
            foreign function identity(input: int32_t): int32_t return input end
        ]], nil, { analysis_only = false })
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
        assert.is_nil(restored.ffi_header_descriptor.filename)
        assert.is_nil(restored.ffi_header_descriptor.bundle_root)
        assert.equal("provider.ffi.h", restored.ffi_header_descriptor.logical_name)
        local original_generate = coder.generate_foreign_header
        coder.generate_foreign_header = function() error("analysis regenerated a native companion") end
        local ok, consumer = pcall(load_module, "consumer", [[
            local provider = import "provider.titan"
            function answer(): integer
                local current = provider.identity(42)
                return 42
            end
        ]], { provider = restored })
        coder.generate_foreign_header = original_generate
        assert.is_true(ok, consumer)
        assert.is_nil(restored.checking_foreign_header)
        assert.is_nil(consumer.ast[1]._foreign_header)
        assert.equal(restored.checking_ffi_header, consumer.ast[1]._ffi_header)
        assert.equal("file", lfs.attributes(restored.checking_ffi_header, "mode"))
    end)

    it("replays inherited C type origins after all project resolver headers close", function()
        local provider = load_module("provider", [[
            foreign import "stdint.h"
            foreign function identity(input: int32_t): int32_t return input end
        ]])
        local consumer = load_module("consumer", [[
            local provider = import "provider.titan"
            foreign function identity(input: int32_t): int32_t
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
        local plan = retained.consumer.ffi_header_descriptor
        assert.equal("consumer.ffi.h", plan.logical_name)
        assert.equal("provider.ffi.h", plan.dependencies[1].logical_name)
        assert.same({ "provider" }, retained.consumer.source_imports)
        local original_parse, parsed = parser.parse, {}
        parser.parse = function(filename, source)
            parsed[#parsed + 1] = filename
            return original_parse(filename, source)
        end
        local ok, result = pcall(load_module, "after_restart", [[
            local consumer = import "consumer.titan"
            function answer(): integer
                local result: foreign int32_t = consumer.identity(42)
                return 42
            end
        ]], retained)
        parser.parse = original_parse
        assert.is_true(ok, result)
        assert.same({ result.filename }, parsed)
        assert.equal(retained.consumer, driver.imported.consumer)
        assert.equal(retained.provider, driver.imported.provider)
        assert.equal(retained.provider.ffi_header_descriptor.digest,
            retained.consumer.ffi_header_descriptor.dependencies[1].digest)
    end)

    it("rejects incompatible project graph and ABI envelopes", function()
        local entry = load_module("durable", [[
            foreign import "stdint.h"
            foreign function identity(input: int32_t): int32_t return input end
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

    it("releases the checked AST after extracting a detached declared manifest", function()
        local weak = setmetatable({}, { __mode = "v" })
        local function extract()
            local entry = load_module("released", [[
                record Box<|A|> item: A end
                local function identity<|A|>(input: A): A
                    local hidden = "BODY_ONLY_MANIFEST_RELEASE_SENTINEL"
                    return input
                end
            ]])
            weak.ast = entry.ast
            weak.body = entry.ast[2].block
            local compact = assert(driver.compact_project_entry(entry))
            driver.imported = { released = compact }
            types.registry = assert(driver.project_entries_registry(driver.imported))
            return compact
        end
        local compact = extract()
        for _ = 1, 3 do collectgarbage("collect") end
        assert.is_nil(weak.ast)
        assert.is_nil(weak.body)
        assert_declarations_only(compact)
        local payload = assert(driver.encode_project_entry(compact))
        assert.is_nil(payload:find("BODY_ONLY_MANIFEST_RELEASE_SENTINEL", 1, true))
        local restored = assert(driver.decode_project_entry(payload))
        assert_declarations_only(restored)
        assert.equal(restored.type.members.Box.type,
            restored.declared_registry["released.Box"])
        assert.equal("Type.FunctionScheme", restored.type.source_members.identity.type._tag)
    end)

    it("does not retain fresh consumer bodies through reused declaration annotations", function()
        local function provider_manifest()
            local entry = load_module("retained_provider", [[
                record Box<|T|> item: T end
                function Box.make(item: T): Box<|T|> return Box<|T|>.new(item) end
                function Box:replace<|U|>(item: U): Box<|U|> return Box<|U|>.new(item) end
                function identity<|T|>(item: T): T return item end
                local counter: integer = 1
                local function hidden(input: integer): integer return input + counter end
            ]])
            return assert(driver.compact_project_entry(entry))
        end
        local initial = provider_manifest()
        local payload = assert(driver.encode_project_entry(initial))
        for _, retained in ipairs({ initial, assert(driver.decode_project_entry(payload)) }) do
            driver.imported = { retained_provider = retained }
            types.registry = driver.project_entries_registry(driver.imported)
            for index = 1, 3 do
                local weak = setmetatable({}, { __mode = "v" })
                local function check_consumer()
                    local consumer = load_module("retained_consumer_" .. index, [[
                        local public = import "retained_provider"
                        local source = import "retained_provider.titan"
                        record Fresh item: integer end
                        function inspect(input: integer): integer
                            local marker = "TRANSIENT_CONSUMER_BODY_SENTINEL"
                            local boxed = public.Box<|integer|>.make { item = input }
                            local read: function (integer): integer = source.hidden
                            local changed = boxed:replace<|Fresh|> { item = Fresh.new(boxed.item) }
                            local captured: function (): integer = function(): integer return read(changed.item.item) + #marker end
                            return source.identity<|integer|>(captured())
                        end
                    ]], { retained_provider = retained })
                    weak.ast = consumer.ast
                    for _, node in ipairs(consumer.ast) do
                        if node._tag == "Ast.TopLevelFunc" and node.name == "inspect" then
                            weak.body = node.block
                        end
                    end
                    assert.is_table(weak.body)
                    -- Inspect the reused object itself before any new compact
                    -- or encode operation can filter a leaked annotation.
                    assert.equal(retained, driver.imported.retained_provider)
                    assert_declarations_only(retained)
                    driver.imported = { retained_provider = retained }
                    types.registry = driver.project_entries_registry(driver.imported)
                end
                check_consumer()
                for _, loader in ipairs(loaders) do assert.is_true(driver.close_loader(loader)) end
                for _ = 1, 3 do collectgarbage("collect") end
                assert.is_nil(weak.ast)
                assert.is_nil(weak.body)
                assert_declarations_only(retained)
            end
            assert.is_nil(assert(driver.encode_project_entry(retained)):find(
                "TRANSIENT_CONSUMER_BODY_SENTINEL", 1, true))
        end
    end)

    it("checks recursive C aliases and source function pointers without native companions", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "wb"))
        assert(file:write([[
            #ifndef TITAN_MANIFEST_C_FIXTURE
            #define TITAN_MANIFEST_C_FIXTURE
            #define MANIFEST_DECL_INT int
            typedef MANIFEST_DECL_INT DeclInt;
            typedef struct Chain { struct Chain *next; int value; int row[3]; } Chain;
            static inline int unused_body(Chain *node) {
                /* CPP_BODY_ONLY_MANIFEST_SENTINEL */
                return node->value + 17;
            }
            #endif
        ]]))
        assert(file:close())
        local generate, parse = coder.generate_foreign_header, parser.parse
        local ok, err = pcall(function()
            local provider = load_module("c_provider", string.format([[
                foreign import %q
                foreign type ManifestChain = Chain
                foreign type ManifestCallback = function (*ManifestChain): DeclInt
                foreign function read(node: *ManifestChain): DeclInt return node.value end
            ]], header))
            local payload = assert(driver.encode_project_entry(provider))
            assert.is_nil(payload:find("CPP_BODY_ONLY_MANIFEST_SENTINEL", 1, true))
            for _, loader in ipairs(loaders) do assert.is_true(driver.close_loader(loader)) end
            driver.imported, types.registry = {}, {}
            local restored = assert(driver.decode_project_entry(payload))
            assert_declarations_only(restored)
            assert.is_nil(restored.type.source_type_members.ManifestChain)
            assert.equal(2, #restored.ffi_header_descriptor.typedef_declarations)
            local owner = types.resolve_c_typedef(
                restored.type.source_members.read.type.params[1].pointee)
            assert.is_true(owner.complete)
            assert.equal(owner, owner.fields.next.type.pointee)
            assert.equal(3, owner.fields.row.type.len)
            coder.generate_foreign_header = function() error("analysis generated .titan.h") end
            local parsed = {}
            parser.parse = function(filename, source)
                parsed[#parsed + 1] = filename
                return parse(filename, source)
            end
            local consumer = load_module("c_consumer", [[
                local provider = import "c_provider.titan"
                foreign function inspect(node: *ManifestChain): DeclInt
                    local callback: foreign ManifestCallback = provider.read
                    return callback(node) + node.row[1] + node.value
                end
            ]], { c_provider = restored })
            assert.same({ consumer.filename }, parsed)
            assert.is_nil(restored.checking_foreign_header)
            assert.is_nil(consumer.checking_foreign_header)
            assert_declarations_only(restored)
            assert_declarations_only(assert(driver.compact_project_entry(consumer)))
        end)
        coder.generate_foreign_header, parser.parse = generate, parse
        os.remove(header)
        assert.is_true(ok, err)
    end)

    it("rechecks dirty roots instead of reusing a compact global import entry", function()
        local first = load_module("dirty", "function answer(): integer return 1 end")
        local compact = assert(driver.compact_project_entry(first))
        driver.imported = { dirty = compact }
        local current = load_module("dirty", 'function answer(): string return "changed" end', { dirty = compact })
        assert.is_table(current.ast)
        assert.not_equal(compact, current)
        assert.equal("Type.String", current.type.members.answer.type.rettypes[1]._tag)
    end)

    it("rejects manifests as native build inputs and reparses source-first roots", function()
        local first = load_module("native_manifest", "function answer(): integer return 1 end")
        local compact = assert(driver.compact_project_entry(first))
        driver.imported, types.registry = {}, {}
        local loader = driver.defaultloader({}, { cached_source_entries = { native_manifest = compact } })
        loaders[#loaders + 1] = loader
        local ok, err = loader("native_manifest")
        assert.is_false(ok)
        assert.match("requires an analysis-only resolver", err, 1, true)
        driver.imported = { native_manifest = compact }
        local current = load_module("native_manifest", "function answer(): integer return 2 end",
            { native_manifest = compact }, { source_first = true, analysis_only = false })
        assert.is_table(current.ast)
        assert.not_equal(compact, current)
    end)

    it("rejects unknown fields, forged source authority and stale C plans", function()
        local first = load_module("malformed_manifest", "record Box item: integer end")
        local payload = assert(driver.encode_project_entry(first))
        local mutations = {
            function(entry) entry.ast = {} end,
            function(entry) entry._analysis_manifest = false end,
            function(entry) entry.type.members.Box.type._decl = { _tag = "Ast.TopLevelRecord" } end,
            function(entry) entry.type.members.Box.type.fields[1].type = { _tag = "Ast.ExpInteger" } end,
            function(entry) entry.ffi_header_descriptor.digest = string.rep("0", 64) end,
            function(entry) entry.ffi_header_descriptor.contents = "void secretly_retained_body(void) {}" end,
            function(entry) entry.source_imports = { "missing" } end,
            function(entry) entry.type.members.Box = {} end,
        }
        local imported, registry = driver.imported, types.registry
        for _, mutate in ipairs(mutations) do
            local envelope = assert(cpp.decode_graph(payload))
            mutate(envelope.entry)
            local result, err = driver.decode_project_entry(assert(cpp.encode_graph(envelope)))
            assert.is_nil(result)
            assert.is_string(err)
            assert.equal(imported, driver.imported)
            assert.equal(registry, types.registry)
        end
        assert.is_nil(driver.decode_project_entry(payload, { module_name = "somewhere_else" }))
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

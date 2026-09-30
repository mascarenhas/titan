local lfs = require "lfs"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local foreigntypes = require "titan-compiler.foreigntypes"
local cdriver = require "c-parser.cdriver"
local cpp = require "c-parser.cpp"

describe("module foreign conversion payloads", function()
    local imported, registry, original_convert, conversions
    local directory, files, directories, loaders, contexts, payloads, adapter

    local function write(path, contents)
        local previous = lfs.attributes(path, "modification")
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        assert(file:close())
        if previous then assert(lfs.touch(path, previous + 1, previous + 1)) end
    end

    before_each(function()
        imported, registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
        directory = os.tmpname()
        assert(os.remove(directory))
        assert(lfs.mkdir(directory))
        files, directories, loaders, contexts, payloads, conversions = {}, {}, {}, {}, {}, 0
        original_convert = foreigntypes.convert
        foreigntypes.convert = function(...)
            conversions = conversions + 1
            return original_convert(...)
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
        foreigntypes.convert = original_convert
        for _, loader in ipairs(loaders) do driver.close_loader(loader) end
        for _, context in ipairs(contexts) do driver.close_resolver_context(context) end
        driver.imported, types.registry = imported, registry
        cdriver.clear_process_cache()
        for _, file in ipairs(files) do os.remove(file) end
        for index = #directories, 1, -1 do assert(lfs.rmdir(directories[index])) end
        assert(lfs.rmdir(directory))
    end)

    local function header(name, contents)
        local path = directory .. "/" .. name
        write(path, contents)
        files[#files + 1] = path
        return path
    end

    local function check(source, cache, provider_source, expected_error)
        driver.imported, types.registry = {}, {}
        cdriver.clear_process_cache()
        cpp.clear_probe_cache()
        local filename = directory .. "/cached.titan"
        local context = driver.new_resolver_context({
            cache_adapter = cache or adapter, extra_ffi_include_dirs = { directory },
        })
        contexts[#contexts + 1] = context
        local overrides = { cached = {
            kind = "generated", main = filename, files = { filename },
            contents = { [filename] = source },
        } }
        if provider_source then
            local provider = directory .. "/provider.titan"
            overrides.provider = {
                kind = "generated", main = provider, files = { provider },
                contents = { [provider] = provider_source },
            }
        end
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { cached = true, provider = provider_source ~= nil },
            source_overrides = overrides,
        })
        loaders[#loaders + 1] = loader
        local ok, result, errors = loader("cached")
        if expected_error then
            local diagnostic = ok and table.concat(errors, "\n") or result
            assert.matches(expected_error, diagnostic, 1, true)
            return driver.imported.cached, driver.compiler_cache_stats({ context = context }), diagnostic
        end
        assert.is_true(ok, result)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return driver.imported.cached, driver.compiler_cache_stats({ context = context })
    end

    local function graph_references(mod)
        local namespace = mod.ast._ffi_namespace
        local current = { ["ffi-namespace"] = namespace, ["ffi-include"] = namespace._include }
        local seen = {}
        local function add(header)
            if seen[header] then return end
            seen[header] = true
            current["ffi-header:" .. header.logical_name] = header
            for _, dependency in ipairs(header.dependencies) do add(dependency) end
        end
        add(namespace._include.generated_header)
        return current
    end

    it("reopens final C definitions after a body-only edit", function()
        header("cached.h", [[
            typedef struct link link;
            struct link { link *next; int item; };
            #define TITAN_TEXT "a + b"
            enum answer { ANSWER = 42 };
            int take_link(link *input);
            typedef struct { int values[4]; } shared_anonymous, same_anonymous;
        ]])
        local source = [[
            foreign import "cached.h"
            function answer(): integer return ffi.ANSWER end
        ]]
        local first, stats = check(source)
        assert.is_true(conversions > 0)
        assert.equal(1, stats.conversion.stores)
        local count = conversions
        local restored, warm = check((source:gsub("return ffi.ANSWER", "return ffi.ANSWER + 1")))
        assert.equal(count, conversions)
        assert.equal(1, warm.conversion.hits)
        assert.not_equal(first.ast._ffi_namespace._type, restored.ast._ffi_namespace._type)
        assert.equal("Type.CModule", restored.ast._ffi_namespace._type._tag)
        assert.is_table(restored.ast._ffi_namespace._type.type_members.link)
        local aliases = restored.ast._ffi_namespace._type.type_members
        assert.equal(types.resolve_c_typedef(aliases.shared_anonymous),
            types.resolve_c_typedef(aliases.same_anonymous))
    end)

    it("retains inherited named scopes in raw and converted cache payloads", function()
        header("scope_leaf.h", [[
            struct inherited_raw { int member; };
            typedef struct inherited_raw *InheritedPointer;
            typedef struct inherited_raw InheritedArray[];
            struct lua_State;
        ]])
        header("scope_parent.h", '#include "scope_leaf.h"\n')
        local provider = [[
            foreign import "scope_parent.h"
            foreign type Item = inherited_raw
        ]]
        local consumer = [[
            local source = import "provider.titan"
            local type ItemOwner = owned *Item
            local type PointerOwner = owned InheritedPointer
            local type ArrayOwner = owned InheritedArray
        ]]
        local expected_scopes
        local function assert_scopes(entry)
            local members = entry.ast._ffi_namespace._type.type_members
            for _, name in ipairs({ "Item", "inherited_raw", "InheritedPointer", "InheritedArray" }) do
                assert.matches("^c%-header%-%x+%.", members[name]._ffi_scope)
                if expected_scopes then assert.equal(expected_scopes[name], members[name]._ffi_scope, name) end
            end
            assert.is_nil(types.resolve_c_typedef(members.lua_State)._ffi_scope)
            assert.equal(members.Item._ffi_scope, entry.ast[2]._type.pointee._ffi_scope)
            for index = 3, 4 do
                assert.equal(members.inherited_raw._ffi_scope, entry.ast[index]._type.pointee._ffi_scope)
            end
            if not expected_scopes then
                expected_scopes = {}
                for _, name in ipairs({ "Item", "inherited_raw", "InheritedPointer", "InheritedArray" }) do
                    expected_scopes[name] = members[name]._ffi_scope
                end
            end
        end
        local first = check(consumer, adapter, provider)
        assert_scopes(first)
        local restored, warm = check(consumer .. "\n-- warm conversion", adapter, provider)
        assert_scopes(restored)
        assert.is_true(warm.conversion.hits > 0)
        for key in pairs(payloads) do
            if key:find("ffi-conversion-v7\0", 1, true) == 1 then payloads[key] = nil end
        end
        local raw_restored, raw_warm = check(consumer .. "\n-- raw header replay", adapter, provider)
        assert_scopes(raw_restored)
        assert.is_true(raw_warm.headers.hits > 0)
        assert.is_true(raw_warm.conversion.misses > 0)
    end)

    it("keeps negative field lookups out of shared header definitions", function()
        header("fields.h", [[
            typedef struct { int member; struct { int member; } nested; } item;
            #define PROJECT nested.member
        ]])
        local filename = directory .. "/cached.titan"
        local source = [[
            foreign import "fields.h"
            local function read(input: foreign *item): integer
                return input.member + input.PROJECT
            end
        ]]
        local context = driver.new_resolver_context({
            cache_adapter = adapter, extra_ffi_include_dirs = { directory },
            analysis_only = true,
        })
        contexts[#contexts + 1] = context
        local function analyze()
            driver.imported, types.registry = {}, {}
            local loader = driver.defaultloader({}, {
                context = context, source_roots = { cached = true },
                source_overrides = { cached = {
                    kind = "generated", main = filename, files = { filename },
                    contents = { [filename] = source },
                } },
            })
            loaders[#loaders + 1] = loader
            local ok, result, errors = loader("cached")
            assert.is_true(ok, result)
            assert.equal(0, #errors, table.concat(errors, "\n"))
        end
        analyze()
        local first = driver.compiler_cache_stats({ context = context })
        assert.equal(1, first.conversion.stores)
        -- Reuse the parsed header while asking for a fresh converted namespace.
        -- Reading the physical member during the first body check must not
        -- have inserted a checked-miss macro memo into that shared header graph.
        for key in pairs(payloads) do
            if key:find("ffi-conversion-v7\0", 1, true) == 1 then
                payloads[key] = nil
            end
        end
        analyze()
        local second = driver.compiler_cache_stats({ context = context })
        assert.is_true(second.headers.hits > first.headers.hits)
        assert.equal(2, second.conversion.stores)
    end)

    it("replays exact constants, recursive layouts, macro projections and callable names", function()
        header("extracted.h", [[
            typedef int word;
            typedef struct item item;
            struct item { item *next; struct { word value; } nested; word values[sizeof(word)]; };
            int named(int count, const char *label);
            extern word callback_extent[sizeof(int (*)(int [static 3]))];
            enum small { SMALL = 7 };
            #define HIGH (0x80000000U >> 31)
            #define NEGATIVE (-1LL)
            #define NOTHING ((item *)0)
            #define PROJECT NEXT
            #define NEXT nested.value
            static inline word inline_body(word value) {
                word parser_body_marker = value + 1;
                return parser_body_marker;
            }
        ]])
        local source = [[
            foreign import "extracted.h"
            foreign function projected(input: *item): word return input.PROJECT end
            function answer(): integer
                local result = ffi.named { count = 1, label = "value" }
                return ffi.HIGH + ffi.SMALL
            end
        ]]
        local first = check(source)
        local count = conversions
        local restored, stats = check((source:gsub('label = "value"', 'label = "changed"')))
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
        local namespace = restored.ast._ffi_namespace._type
        assert.same({ "count", "label" }, namespace.members.named.paramnames)
        local item = types.resolve_c_typedef(namespace.type_members.item)
        assert.equal(item, types.resolve_c_typedef(item.fields.next.type.pointee))
        assert.equal("sizeof", item.fields.values.type.len.op)
        assert.equal("Type.CPointer", namespace.members.NOTHING.type._tag)
        assert.equal("unsigned int", namespace.members.HIGH.type.spelling)
        assert.equal("long long", namespace.members.NEGATIVE.type.spelling)
        assert.equal(first.ast._ffi_namespace._type.members.SMALL.type._c_declaration_spelling,
            namespace.members.SMALL.type._c_declaration_spelling)
        for _, payload in pairs(payloads) do
            assert.is_nil(payload:find("parser_body_marker", 1, true))
            for _, forbidden in ipairs({ "parser_body_marker", "candidate_classes", "integer_literals",
                "macro_definitions", "macro_changes", "foreign_name_history", "converted_aggregates",
                "raw_spelling" }) do
                assert.is_nil(payload:find("s" .. string.pack(">I4", #forbidden) .. forbidden, 1, true), forbidden)
            end
        end
    end)

    it("preserves empty and unsupported field macro failures after replay", function()
        header("fields.h", [[
            typedef int word;
            typedef struct { word blocked; word empty; word removed; word function_like; } item;
            #define blocked 17
            #define empty
            #define removed missing.member
            #undef removed
            #define function_like(value) value
        ]])
        local source = [[
            foreign import "fields.h"
            foreign function observed(item: *item): word return item.removed + item.function_like end
        ]]
        check(source)
        local count = conversions
        for _, field in ipairs({ "blocked", "empty" }) do
            local rejected = source:gsub("item%.removed %+ item%.function_like", "item." .. field)
            local _, stats, diagnostic = check(rejected, nil, nil, "active object-like macro")
            assert.equal(count, conversions)
            assert.equal(1, stats.conversion.hits)
            assert.matches("C field token '" .. field .. "'", diagnostic, 1, true)
        end
        local _, stats = check(source)
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
    end)

    it("rejects well-formed envelopes that contain obsolete checker roots", function()
        header("closed.h", "typedef int item_type;\n")
        local source = 'foreign import "closed.h"\nfunction answer(): integer return 42 end'
        local first = check(source)
        local refs = graph_references(first)
        local external = {}
        for name, value in pairs(refs) do external[value] = name end
        for key, payload in pairs(payloads) do
            if key:find("ffi-conversion-v7\0", 1, true) == 1 then
                local snapshot = assert(cpp.decode_graph(payload, { references = refs }))
                snapshot.converted_enums = {}
                payloads[key] = assert(cpp.encode_graph(snapshot, { external = external }))
            end
        end
        local count = conversions
        local _, stats = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, stats.conversion.misses)
    end)

    it("preserves cross-header completion, import rebinding and expanded macro spelling", function()
        header("first.h", [[
            typedef int count;
            typedef struct shared shared;
            int read_shared(shared *input);
            #define STRINGIFY(x) #x
            #define TEXT STRINGIFY(a + b)
        ]])
        header("second.h", [[
            struct shared { int item; };
            int read_shared(struct shared *input);
        ]])
        local source = [[
            foreign import "first.h"
            foreign import "second.h"
            foreign function identity(input: count): count return input end
            function answer(): integer local text = ffi.TEXT return 42 end
        ]]
        check(source)
        local count = conversions
        local restored, stats = check(source)
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
        local first = restored.ast._ffi_namespace._type
        for key, payload in pairs(payloads) do
            if key:sub(1, #"ffi-conversion-v7\0") == "ffi-conversion-v7\0" then
                local snapshot = assert(cpp.decode_graph(payload, { references = graph_references(restored) }))
                assert.equal("just", snapshot.field_macros.TEXT.tag)
                assert.equal('"a + b"', snapshot.field_macros.TEXT.value.replacement)
                assert.is_nil(snapshot.roots)
                assert.is_nil(snapshot.converted_enums)
                assert.is_nil(snapshot.converted_aggregates)
            end
        end
        assert.is_table(first.type_members.shared)
    end)

    it("rejects legacy false extents in converted C definition snapshots", function()
        header("extents.h", "typedef struct { int values[4]; unsigned flag:1; } extent_holder;\n")
        local mod = check('foreign import "extents.h"\nfunction answer(): integer return 42 end')
        local definitions = require "titan-compiler.cdefinitioncache"
        local snapshots = 0
        for key, payload in pairs(payloads) do
            if key:sub(1, #"ffi-conversion-v7\0") == "ffi-conversion-v7\0" then
                snapshots = snapshots + 1
                local snapshot = assert(cpp.decode_graph(payload, { references = graph_references(mod) }))
                local options = {
                    strict = true,
                    external = { [mod.ast._ffi_namespace._include] = "ffi-include" },
                }
                local owner = types.resolve_c_typedef(snapshot.namespace_type.type_members.extent_holder)
                local array, field = owner.fields.values.type, owner.fields.flag
                assert.is_not_nil(array.len)
                assert.is_not_nil(field.bitfield)
                for _, target in ipairs({ { array, "len" }, { field, "bitfield" } }) do
                    local node, name = target[1], target[2]
                    local previous = node[name]
                    node[name] = false
                    local ok, err = pcall(definitions.foreign, snapshot, options)
                    assert.is_false(ok)
                    assert.matches("expected C extent expression", err, 1, true)
                    node[name] = nil
                    local restored = definitions.foreign(snapshot, options)
                    local restored_owner = types.resolve_c_typedef(restored.namespace_type.type_members.extent_holder)
                    if name == "len" then assert.is_nil(restored_owner.fields.values.type.len)
                    else assert.is_nil(restored_owner.fields.flag.bitfield) end
                    node[name] = previous
                end
            end
        end
        assert.equal(1, snapshots)
    end)

    it("invalidates changed-mtime header changes and corrupt conversion blobs", function()
        local path = header("cached.h", "typedef int item_type;\n")
        local source = [[
            foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        check(source)
        local count = conversions
        for key in pairs(payloads) do
            if key:sub(1, #"ffi-conversion-v7\0") == "ffi-conversion-v7\0" then payloads[key] = "corrupt" end
        end
        local _, corrupt = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, corrupt.conversion.misses)
        count = conversions
        local stamp = assert(lfs.attributes(path, "modification"))
        write(path, "typedef unsigned item_type;\n")
        assert(lfs.touch(path, stamp + 1, stamp + 1))
        local _, changed = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, changed.conversion.misses)
    end)

    it("treats malformed transported observation inputs as a disposable cache miss", function()
        header("cached.h", "typedef int item_type;\n")
        local source = 'foreign import "cached.h"\nfunction answer(): integer return 42 end'
        check(source)
        local count, get = conversions, adapter.get
        adapter.get = function(kind, key)
            if kind == "ffi-conversion-v7" then
                local malformed = {}
                setmetatable(malformed, { __index = malformed })
                return get(kind, key), { malformed }
            end
            return get(kind, key)
        end
        local _, stats = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, stats.conversion.misses)
        assert.equal(0, stats.conversion.hits)
    end)

    it("preserves cancellation while validating transported observation metadata", function()
        header("cached.h", "typedef int item_type;\n")
        local source = "foreign import \"cached.h\"\nfunction answer(): integer return 42 end"
        check(source)
        local get, cancellation = adapter.get, {}
        adapter.get = function(kind, key)
            if kind == "ffi-conversion-v7" then
                local malformed = setmetatable({}, { __index = function() error(cancellation, 0) end })
                return get(kind, key), { malformed }
            end
            return get(kind, key)
        end
        local ok, err = pcall(check, source)
        assert.is_false(ok)
        assert.equal(cancellation, err)
    end)

    it("refreshes same-content touches through metadata while preserving both graphs", function()
        local path = header("cached.h", "typedef int touched_type;\n")
        local source = [[
            foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        local metadata, refreshes = {}, {}
        adapter.get = function(kind, key)
            local id = kind .. "\0" .. key
            return payloads[id], metadata[id]
        end
        adapter.put = function(kind, key, payload, inputs)
            local id = kind .. "\0" .. key
            payloads[id], metadata[id] = payload, inputs
            return true
        end
        adapter.refresh_inputs = function(kind, key, inputs)
            metadata[kind .. "\0" .. key] = inputs
            refreshes[kind] = (refreshes[kind] or 0) + 1
            return true
        end
        local first = check(source)
        local interface = assert(driver.serialize_source_interface(first))
        local original = {}
        for key, payload in pairs(payloads) do original[key] = payload end
        local count = conversions
        local stamp = assert(lfs.attributes(path, "modification"))
        assert(lfs.touch(path, stamp + 1, stamp + 1))
        local touched, stats = check(source)
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
        assert.equal(interface, assert(driver.serialize_source_interface(touched)))
        assert.same(original, payloads)
        assert.is_true((refreshes["c-header-v6"] or 0) > 0)
        assert.equal(1, refreshes["ffi-conversion-v7"])
        local _, warm = check(source)
        assert.equal(count, conversions)
        assert.equal(0, warm.headers.file_reads)
        assert.equal(0, warm.headers.file_hashes)
        assert.equal(1, refreshes["ffi-conversion-v7"])
    end)

    it("replays a fresh source-import context after its provider body changes", function()
        header("provider.h", "typedef int provider_count;\n")
        header("consumer.h", "typedef int consumer_count;\n")
        local provider = [[
            foreign import "provider.h"
            foreign function identity(input: provider_count): provider_count
                return input
            end
        ]]
        local source = [[
            foreign import "consumer.h"
            local provider = import "provider.titan"
            function answer(): integer
                local current = provider.identity(42)
                return 42
            end
        ]]
        check(source, nil, provider)
        local count = conversions
        local restored, stats = check(source, nil,
            (provider:gsub("return input", "return input + 1")))
        assert.equal(count, conversions)
        assert.equal(2, stats.conversion.hits)
        assert.is_true(restored.ast[2]._source_import)
        local header_path = restored.ast[2]._foreign_header
        assert.equal("file", lfs.attributes(header_path, "mode"))
    end)

    it("invalidates an earlier missing nested-header candidate becoming present", function()
        local nested = directory .. "/nested"
        assert(lfs.mkdir(nested))
        directories[#directories + 1] = nested
        header("nested/outer.h", '#include "selected.h"\n')
        header("selected.h", "typedef int selected_type;\n")
        local source = [[
            foreign import "nested/outer.h"
            function answer(): integer return 42 end
        ]]
        check(source)
        local count = conversions
        header("nested/selected.h", "typedef unsigned selected_type;\n")
        local restored, stats = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, stats.conversion.misses)
        local seen = false
        for _, input in ipairs(restored.c_header_dependencies) do
            if input.kind == "file" and input.path == nested .. "/selected.h" then seen = true end
        end
        assert.is_true(seen)
    end)

    it("supports a read-only transport and propagates cancellation objects", function()
        header("cached.h", "typedef int item_type;\n")
        local source = [[
            foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        check(source)
        local count = conversions
        local _, stats = check(source, { get = adapter.get })
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
        assert.equal(0, stats.conversion.stores)
        local cancelled = {}
        local ok, failure = pcall(check, source, {
            get = function() error(cancelled, 0) end,
        })
        assert.is_false(ok)
        assert.equal(cancelled, failure)
    end)

    it("forwards conversion checksums and preserves hash cancellation", function()
        header("cached.h", "typedef int item_type;\n")
        local source = [[
            foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        local hashes = 0
        adapter.sha256_binary = function(bytes)
            if bytes:find("ffi-conversion-v7", 1, true) then hashes = hashes + 1 end
            return require("titan-compiler.sha256").binary(bytes)
        end
        check(source)
        assert.equal(1, hashes)
        local count = conversions
        check((source:gsub("return 42", "return 43")))
        assert.equal(2, hashes)
        assert.equal(count, conversions)
        local cancelled = {}
        adapter.sha256_binary = function(bytes)
            if bytes:find("ffi-conversion-v7", 1, true) then error(cancelled, 0) end
            return require("titan-compiler.sha256").binary(bytes)
        end
        local ok, err = pcall(check, source)
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)
end)

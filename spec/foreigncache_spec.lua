local lfs = require "lfs"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local foreigntypes = require "titan-compiler.foreigntypes"
local cdriver = require "c-parser.cdriver"
local cpp = require "c-parser.cpp"

describe("ordered foreign conversion payloads", function()
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

    local function check(source, cache, provider_source)
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
        assert.is_true(ok, result)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return driver.imported.cached, driver.compiler_cache_stats({ context = context })
    end

    it("reopens the complete conversion graph after a body-only edit", function()
        header("cached.h", [[
            typedef struct link link;
            struct link { link *next; int item; };
            #define TITAN_TEXT "a + b"
            enum answer { ANSWER = 42 };
            int take_link(link *input);
        ]])
        local source = [[
            local c = foreign import "cached.h"
            function answer(): integer return c.ANSWER end
        ]]
        local first, stats = check(source)
        assert.is_true(conversions > 0)
        assert.equal(1, stats.conversion.stores)
        local count = conversions
        local restored, warm = check((source:gsub("return c.ANSWER", "return c.ANSWER + 1")))
        assert.equal(count, conversions)
        assert.equal(1, warm.conversion.hits)
        assert.not_equal(first.ast[1]._type, restored.ast[1]._type)
        assert.equal("Type.CModule", restored.ast[1]._type._tag)
        assert.is_table(restored.ast[1]._type.type_members.link)
    end)

    it("preserves cross-header completion, import rebinding and macro spacing", function()
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
            local first = foreign import "first.h"
            local second = foreign import "second.h"
            foreign function identity(input: first.count): first.count return input end
            function answer(): integer local text = first.TEXT return 42 end
        ]]
        check(source)
        local count = conversions
        local restored, stats = check(source)
        assert.equal(count, conversions)
        assert.equal(1, stats.conversion.hits)
        local first = restored.ast[1]._type
        assert.equal('"a + b"', cpp.expand_macro("TEXT",
            restored.type._source_c_context.macro_definitions))
        for key, payload in pairs(payloads) do
            if key:sub(1, 18) == "ffi-conversion-v1\0" then
                local snapshot = assert(cpp.decode_graph(payload, { references = {
                    ["foreign-import:1"] = restored.ast[1],
                    ["foreign-import:2"] = restored.ast[2],
                } }))
                assert.equal('"a + b"', cpp.expand_macro("TEXT",
                    snapshot.roots.foreign_macro_definitions))
            end
        end
        assert.is_table(first.type_members.shared)
    end)

    it("invalidates changed-mtime header changes and corrupt conversion blobs", function()
        local path = header("cached.h", "typedef int item_type;\n")
        local source = [[
            local c = foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        check(source)
        local count = conversions
        for key in pairs(payloads) do
            if key:sub(1, 18) == "ffi-conversion-v1\0" then payloads[key] = "corrupt" end
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

    it("treats malformed literal observation inputs as a disposable cache miss", function()
        header("cached.h", "typedef int item_type;\n")
        local source = 'local c = foreign import "cached.h"\nfunction answer(): integer return 42 end'
        local first = check(source)
        local count, corrupted = conversions, false
        for key, payload in pairs(payloads) do
            if key:sub(1, 18) == "ffi-conversion-v1\0" then
                local snapshot = assert(cpp.decode_graph(payload, {
                    references = { ["foreign-import:1"] = first.ast[1] },
                }))
                local malformed = {}
                setmetatable(malformed, { __index = malformed })
                snapshot.node_includes[1].c_header_dependencies[1] = malformed
                payloads[key] = assert(cpp.encode_graph(snapshot, {
                    external = { [first.ast[1]] = "foreign-import:1" },
                }))
                corrupted = true
            end
        end
        assert.is_true(corrupted)
        local _, stats = check(source)
        assert.is_true(conversions > count)
        assert.equal(1, stats.conversion.misses)
        assert.equal(0, stats.conversion.hits)
    end)

    it("preserves cancellation while validating transported observation metadata", function()
        header("cached.h", "typedef int item_type;\n")
        local source = 'local c = foreign import "cached.h"\nfunction answer(): integer return 42 end'
        check(source)
        local get, cancellation = adapter.get, {}
        adapter.get = function(kind, key)
            if kind == "ffi-conversion-v1" then
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
            local c = foreign import "cached.h"
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
        assert.is_true((refreshes["c-header-v1"] or 0) > 0)
        assert.equal(1, refreshes["ffi-conversion-v1"])
        local _, warm = check(source)
        assert.equal(count, conversions)
        assert.equal(0, warm.headers.file_reads)
        assert.equal(0, warm.headers.file_hashes)
        assert.equal(1, refreshes["ffi-conversion-v1"])
    end)

    it("replays a fresh source-import context after its provider body changes", function()
        header("provider.h", "typedef int provider_count;\n")
        header("consumer.h", "typedef int consumer_count;\n")
        local provider = [[
            local c = foreign import "provider.h"
            foreign function identity(input: c.provider_count): c.provider_count
                return input
            end
        ]]
        local source = [[
            local c = foreign import "consumer.h"
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
            local c = foreign import "nested/outer.h"
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
            local c = foreign import "cached.h"
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
            local c = foreign import "cached.h"
            function answer(): integer return 42 end
        ]]
        local hashes = 0
        adapter.sha256_binary = function(bytes)
            if bytes:find("titan-ffi-conversion-v1", 1, true) then hashes = hashes + 1 end
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
            if bytes:find("titan-ffi-conversion-v1", 1, true) then error(cancelled, 0) end
            return require("titan-compiler.sha256").binary(bytes)
        end
        local ok, err = pcall(check, source)
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)
end)

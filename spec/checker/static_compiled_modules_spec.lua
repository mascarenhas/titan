local lfs = require "lfs"
local assert = require "luassert"

local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local titan = require "titan"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function ensure_directory(path)
    if path == "" or lfs.attributes(path, "mode") == "directory" then
        return
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path then ensure_directory(parent) end
    assert(lfs.mkdir(path))
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
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

local function public_record(fqtn, fields)
    local params, paramnames = {}, {}
    for _, field in ipairs(fields) do
        params[#params + 1] = field.type
        paramnames[#paramnames + 1] = field.name
    end
    local constructor = types.StaticMethod(
        fqtn, "new", params, { types.Nominal(fqtn) },
        false, false, paramnames)
    return types.Record(
        fqtn, fields, { new = constructor }, {}, #fields)
end

local function owner_interface(modname, record_name)
    local fqtn = modname .. "." .. record_name
    local record = public_record(fqtn, {})
    local member = types.ModuleMember(
        modname, record_name, record, false)
    return types.Module(modname, { member }), record
end

local function facade_interface(modname, alias_name, owner_fqtn)
    return types.Module(modname, {}, {
        [alias_name] = types.Nominal(owner_fqtn),
    })
end

local function constraints(context, owner)
    local found = {}
    for _, constraint in pairs(
            context.native_constraints[owner] or {}) do
        found[#found + 1] = {
            binding = constraint.binding,
            provider = constraint.provider,
            exposer = constraint.exposer,
        }
    end
    table.sort(found, function(left, right)
        return table.concat({
            left.binding or "", left.provider or "", left.exposer or "",
        }, "\0") < table.concat({
            right.binding or "", right.provider or "", right.exposer or "",
        }, "\0")
    end)
    return found
end

describe("static compiled-module checker provenance", function()
    local root
    local source
    local binary
    local previous

    local function cache_provider(context, relative, module_types)
        local filename = binary .. "/" .. relative
        local parent = filename:match("^(.*)/[^/]+$")
        if parent then ensure_directory(parent) end
        write_file(filename, "cached staticmetadata fixture\n")

        local provider = {
            archive = filename,
            relative_archive = relative,
            entries = {},
            key_order = {},
        }
        for name, modtype in pairs(module_types) do
            local serialized = types.serialize(modtype)
            local payload = assert(staticmetadata.render(
                name, driver.TITAN_VER, serialized))
            local entry = assert(staticmetadata.validate(
                payload, filename .. ":" .. name, {
                    expected_abi = driver.TITAN_VER,
                    validate_types = function(entry_name, entry_types, origin)
                        return driver.decode_module_interface(
                            entry_types, entry_name, origin)
                    end,
                }))
            entry.type = assert(entry.decoded_types)
            provider.entries[name] = entry
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

    it("recovers a direct-carried owner without importing archive siblings",
       function()
        local owner, _ = owner_interface("pkg.owner", "Box")
        local facade = facade_interface(
            "pkg.facade", "Box", "pkg.owner.Box")
        local unrelated = types.Module("pkg.unused", {})
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "pkg.a", {
            ["pkg.facade"] = facade,
            ["pkg.owner"] = owner,
            ["pkg.unused"] = unrelated,
        })
        local loader = driver.defaultloader({}, { context = context })

        local modtype, errors = checker.checkimport("pkg.facade", loader)
        assert.truthy(modtype)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported["pkg.facade"].kind)
        assert.is_nil(driver.imported["pkg.owner"])
        assert.is_nil(driver.imported["pkg.unused"])
        assert.truthy(types.registry["pkg.owner.Box"])
        assert.same({
            {
                binding = "direct-carried",
                provider = provider.archive,
                exposer = "pkg.facade",
            },
        }, constraints(context, "pkg.owner"))

        -- Static provenance is carried separately from the canonical logical
        -- DSO path. It must not leak into Type.Module.file or serialization.
        assert.equal("pkg/facade.so", modtype.file)
        assert.is_nil(types.serialize(modtype):find(
            provider.archive, 1, true))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.is_nil(driver.imported["pkg.owner"])
        assert.is_nil(driver.imported["pkg.unused"])
        assert.equal("direct", context.native_bindings["pkg.owner"])
        assert.equal("direct", context.native_bindings["pkg.unused"])
        assert.same({ provider }, context.selected_static_providers)
    end)

    it("typechecks a rich exported surface from archive metadata",
       function()
        local provider_source = [[
counter: integer = 7

record Box
    n: integer
end

union Result
    none
    local hidden: integer
    box: Box
end

interface Incrementer
    function add(delta: integer): integer
end

function Box.make(n: integer): Box
    return Box.new(n)
end

function Box:add(delta: integer): integer
    return self.n + delta
end

type Alias = Box

function combine(left: integer, right: integer): integer
    return left * 10 + right
end

function sum(...: integer): integer
    local total: integer = 0
    for i = 1, #... do
        total = total + ...[i]
    end
    return total
end

function labels(): (...: string)
    return "left", "right"
end

function hidden_result(): Result
    return Result.hidden(99)
end
]]
        local provider_filename = source .. "/rich/api.titan"
        local provider_ast, parse_error =
            parser.parse(provider_filename, provider_source)
        assert.truthy(provider_ast, parse_error)
        local provider_type, provider_errors = checker.check(
            "rich.api", provider_ast, provider_source, provider_filename)
        assert.equal(0, #provider_errors, table.concat(provider_errors, "\n"))

        -- The consumer must recover every shape from the serialized archive
        -- interface, not from the source checker's registry or imported cache.
        driver.imported = {}
        types.registry = {}
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "rich.a", {
            ["rich.api"] = provider_type,
        })
        local loader = driver.defaultloader({}, { context = context })
        local consumer_source = [[
local api = import "rich.api"

function use_everything(): integer
    local before: integer = api.counter
    api.counter = before + 1
    local encoded = api.combine { right = 2, left = 4 }
    local box: api.Alias = api.Box.make { n = encoded }
    local incrementer: api.Incrementer = box
    local wrap: (api.Box) -> api.Result = api.Result.box
    local result = wrap(box)
    local first: string?, second: string? = api.labels()
    local count = api.sum(1, 2, 3)
    case result
    when box: selected then
        return incrementer:add { delta = count }
    when none then
        return 0
    else
        return -1
    end
end
]]
        local consumer_filename = source .. "/rich/consumer.titan"
        local consumer_ast, consumer_parse_error =
            parser.parse(consumer_filename, consumer_source)
        assert.truthy(consumer_ast, consumer_parse_error)
        local _, consumer_errors = checker.check(
            "rich.consumer", consumer_ast, consumer_source,
            consumer_filename, loader)
        assert.equal(0, #consumer_errors,
            table.concat(consumer_errors, "\n"))
        assert.equal("static", driver.imported["rich.api"].kind)
        assert.equal(provider.archive,
            driver.imported["rich.api"].static_archive)
        assert.truthy(types.registry["rich.api.Box"])
        local interface =
            assert(types.registry["rich.api.Incrementer"])
        assert.equal("Type.Interface", interface._tag)
        assert.equal("add", interface.methods[1].name)
        assert.is_true(interface.methods.add == interface.methods[1])
        local union = assert(types.registry["rich.api.Result"])
        assert.equal(3, union.nvariants)
        assert.equal(2, #union.variants)
        assert.equal(0, union.variants.none.index)
        assert.equal(2, union.variants.box.index)
        assert.is_nil(union.variants.hidden)
        assert.is_nil(union.functions.hidden)
        assert.is_false(union.functions.box.paramnames)
        assert.equal("rich.api.Box", union.variants.box.payload.fqtn)
        assert.equal(
            types.serialize(provider_type),
            types.serialize(driver.imported["rich.api"].type))
    end)

    it("preserves the exposing provider through recursive nominal recovery",
       function()
        local owner = owner_interface("right.owner", "Box")
        local bridge_record = public_record("middle.bridge.Link", {
            types.Field("middle.bridge.Link", "box",
                types.Nominal("right.owner.Box"), 0),
        })
        local bridge_interface = types.Interface(
            "middle.bridge.BoxConsumer", {
                types.Method(
                    "middle.bridge.BoxConsumer", "consume",
                    {types.Nominal("right.owner.Box")}, {},
                    false, false, {"box"}),
            })
        local bridge = types.Module("middle.bridge", {
            types.ModuleMember(
                "middle.bridge", "Link", bridge_record, false),
        }, {
            BoxConsumer = bridge_interface,
        })
        local facade = facade_interface(
            "left.facade", "Link", "middle.bridge.Link")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "left.a", {
            ["left.facade"] = facade,
            ["middle.bridge"] = bridge,
            ["right.owner"] = owner,
        })
        cache_provider(context, "right.a", {
            ["right.owner"] = owner,
        })
        local loader = driver.defaultloader({}, { context = context })

        local modtype, errors = checker.checkimport("left.facade", loader)
        assert.truthy(modtype)
        assert.equal(0, #errors)
        assert.truthy(types.registry["middle.bridge.Link"])
        local recovered_interface =
            assert(types.registry["middle.bridge.BoxConsumer"])
        assert.equal("Type.Interface", recovered_interface._tag)
        assert.equal("consume", recovered_interface.methods[1].name)
        assert.equal("right.owner.Box",
            recovered_interface.methods[1].params[1].fqtn)
        assert.truthy(types.registry["right.owner.Box"])
        assert.is_nil(driver.imported["middle.bridge"])
        assert.is_nil(driver.imported["right.owner"])
        assert.same({
            {
                binding = "direct-carried",
                provider = provider.archive,
                exposer = "left.facade",
            },
        }, constraints(context, "middle.bridge"))
        assert.same({
            {
                binding = "direct-carried",
                provider = provider.archive,
                exposer = "left.facade",
            },
        }, constraints(context, "right.owner"))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.same({ provider }, context.selected_static_providers)
    end)

    it("replays nested contextual DSO edges through finalization cycles",
       function()
        local leaf_record = public_record("chain.leaf.Box", {
            types.Field("chain.leaf.Box", "back",
                types.Nominal("chain.mid.Link"), 0),
        })
        local leaf = types.Module("chain.leaf", {
            types.ModuleMember(
                "chain.leaf", "Box", leaf_record, false),
        })
        local mid_record = public_record("chain.mid.Link", {
            types.Field("chain.mid.Link", "box",
                types.Nominal("chain.leaf.Box"), 0),
        })
        local mid = types.Module("chain.mid", {
            types.ModuleMember("chain.mid", "Link", mid_record, false),
        })
        local api = facade_interface(
            "chain.api", "Link", "chain.mid.Link")
        local dynamic = binary .. "/chain.so"
        write_file(dynamic, "mock multi-protocol DSO\n")
        local protocols = {
            chain_api = types.serialize(api),
            chain_leaf = types.serialize(leaf),
            chain_mid = types.serialize(mid),
        }
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic, filename)
            local prefix = symbol:match("^(.*)_abi$")
            if prefix and protocols[prefix] then
                return function() return driver.TITAN_VER end
            end
            prefix = symbol:match("^(.*)_types$")
            if prefix and protocols[prefix] then
                return function() return protocols[prefix] end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local context = driver.new_resolver_context()
        local loader = driver.defaultloader({}, { context = context })
        local modtype, errors = checker.checkimport("chain.api", loader)
        assert.truthy(modtype)
        assert.equal(0, #errors)
        assert.truthy(types.registry["chain.mid.Link"])
        assert.truthy(types.registry["chain.leaf.Box"])

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        for _, owner in ipairs({ "chain.mid", "chain.leaf" }) do
            assert.same({
                {
                    binding = "dynamic-global",
                    provider = dynamic,
                    exposer = "chain.api",
                },
            }, constraints(context, owner))
            assert.equal("global", context.native_bindings[owner])
            assert.equal(owner,
                context.native_interface_types[owner].name)
            assert.is_nil(driver.imported[owner])
        end
    end)

    it("uses a visible owner archive only for producer-dynamic type recovery",
       function()
        local owner = owner_interface("dyn.owner", "Box")
        local facade = facade_interface(
            "dyn.facade", "Box", "dyn.owner.Box")
        local context = driver.new_resolver_context()
        local owner_provider = cache_provider(context, "dyn/owner.a", {
            ["dyn.owner"] = owner,
        })
        local dynamic = binary .. "/dyn.so"
        write_file(dynamic, "mock exposing DSO\n")
        local facade_types = types.serialize(facade)
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic, filename)
            if symbol == "dyn_facade_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "dyn_facade_types" then
                return function() return facade_types end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local loader = driver.defaultloader({}, { context = context })
        local modtype, errors = checker.checkimport("dyn.facade", loader)
        assert.truthy(modtype)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported["dyn.facade"].kind)
        assert.is_nil(driver.imported["dyn.owner"])
        assert.truthy(types.registry["dyn.owner.Box"])
        assert.same({
            {
                binding = "dynamic-global",
                provider = dynamic,
                exposer = "dyn.facade",
            },
        }, constraints(context, "dyn.owner"))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.same({}, context.selected_static_providers)
        assert.is_nil(driver.imported["dyn.owner"])
        assert.equal("global", context.native_bindings["dyn.owner"])
        assert.is_nil(context.native_static_names["dyn.owner"])
        assert.equal(owner_provider,
            context.provider_cache[owner_provider.archive])
    end)

    it("rejects an independently resolved DSO owner required dynamically by an archive",
       function()
        local owner = owner_interface("identity.owner", "Box")
        local facade = facade_interface(
            "identity.facade", "Box", "identity.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local facade_provider = cache_provider(
            context, "identity/facade.a", {
                ["identity.facade"] = facade,
            })
        local owner_dso = binary .. "/identity/owner.so"
        ensure_directory(binary .. "/identity")
        write_file(owner_dso, "mock independently selected owner DSO\n")
        local serialized_owner = types.serialize(owner)
        titan._loadlib = function(filename, symbol)
            assert.equal(owner_dso, filename)
            if symbol == "identity_owner_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "identity_owner_types" then
                return function() return serialized_owner end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local loader = driver.defaultloader({}, { context = context })
        local facade_type, facade_errors =
            checker.checkimport("identity.facade", loader)
        assert.truthy(facade_type)
        assert.equal(0, #facade_errors)
        assert.is_nil(driver.imported["identity.owner"])
        assert.same({
            {
                binding = "dynamic-global",
                provider = facade_provider.archive,
                exposer = "identity.facade",
            },
        }, constraints(context, "identity.owner"))

        local owner_type, owner_errors =
            checker.checkimport("identity.owner", loader)
        assert.truthy(owner_type)
        assert.equal(0, #owner_errors)
        assert.equal("dynamic", driver.imported["identity.owner"].kind)
        assert.equal(owner_dso, driver.imported["identity.owner"].filename)

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match(
            "logical owner 'identity.owner' resolved independently as dynamic",
            message, 1, true)
        assert.match(facade_provider.archive, message, 1, true)
        assert.match("requires its producer-chosen dynamic identity",
            message, 1, true)
    end)

    it("rejects a source owner against an archive facade's dynamic identity",
       function()
        local facade = facade_interface(
            "mixed.facade", "Box", "mixed.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "mixed/facade.a", {
            ["mixed.facade"] = facade,
        })
        ensure_directory(source .. "/mixed")
        write_file(source .. "/mixed/owner.titan", [[
            record Box
                n: integer
            end
        ]])
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { ["mixed.owner"] = true },
        })

        local owner_type, owner_errors =
            checker.checkimport("mixed.owner", loader)
        assert.truthy(owner_type)
        assert.equal(0, #owner_errors)
        assert.equal("source", driver.imported["mixed.owner"].kind)

        local facade_type, facade_errors =
            checker.checkimport("mixed.facade", loader)
        assert.truthy(facade_type)
        assert.equal(0, #facade_errors)
        assert.equal("static", driver.imported["mixed.facade"].kind)
        assert.is_nil(provider.entries["mixed.owner"])
        assert.same({
            {
                binding = "dynamic-global",
                provider = provider.archive,
                exposer = "mixed.facade",
            },
        }, constraints(context, "mixed.owner"))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match(
            "logical owner 'mixed.owner' resolved independently as source",
            message, 1, true)
        assert.match(
            "selected provider '" .. provider.archive ..
                "' requires its producer-chosen dynamic identity",
            message, 1, true)
    end)

    it("records exposure even when the nominal was already registered",
       function()
        local owner = owner_interface("known.owner", "Box")
        local facade = facade_interface(
            "known.facade", "Box", "known.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "known.a", {
            ["known.facade"] = facade,
            ["known.owner"] = owner,
        })
        types.registry["known.owner.Box"] =
            provider.entries["known.owner"].type.members[1].type

        local loader = driver.defaultloader({}, { context = context })
        local modtype, errors =
            checker.checkimport("known.facade", loader)
        assert.truthy(modtype)
        assert.equal(0, #errors)
        assert.same({
            {
                binding = "direct-carried",
                provider = provider.archive,
                exposer = "known.facade",
            },
        }, constraints(context, "known.owner"))
        assert.is_nil(driver.imported["known.owner"])
    end)

    it("recomputes exposure edges after an explicit source replaces a provider",
       function()
        local owner = owner_interface("replace.owner", "Box")
        local facade = facade_interface(
            "replace.facade", "Box", "replace.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local provider = cache_provider(context, "replace.a", {
            ["replace.facade"] = facade,
            ["replace.owner"] = owner,
        })
        ensure_directory(source .. "/replace")
        write_file(source .. "/replace/facade.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        local source_roots = {}
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = source_roots,
        })

        local compiled, compiled_errors =
            checker.checkimport("replace.facade", loader)
        assert.truthy(compiled)
        assert.equal(0, #compiled_errors)
        assert.same({
            {
                binding = "direct-carried",
                provider = provider.archive,
                exposer = "replace.facade",
            },
        }, constraints(context, "replace.owner"))

        source_roots["replace.facade"] = true
        local ok, source_type, source_errors = loader("replace.facade")
        assert.truthy(ok)
        assert.equal(0, #source_errors)
        assert.equal("replace.facade", source_type.name)
        assert.equal("source", driver.imported["replace.facade"].kind)

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.same({}, context.selected_static_providers)
        assert.same({}, constraints(context, "replace.owner"))
        assert.is_nil(context.native_bindings["replace.owner"])
        assert.equal("direct",
            context.native_bindings["replace.facade"])
    end)

    it("rejects producer-dynamic owner constraints from different providers",
       function()
        local owner = owner_interface("shared.owner", "Box")
        local left = facade_interface(
            "left.facade", "Box", "shared.owner.Box")
        local right = facade_interface(
            "right.facade", "Box", "shared.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local left_provider = cache_provider(context, "left.a", {
            ["left.facade"] = left,
        })
        local right_provider = cache_provider(context, "right.a", {
            ["right.facade"] = right,
        })
        cache_provider(context, "shared/owner.a", {
            ["shared.owner"] = owner,
        })
        local loader = driver.defaultloader({}, { context = context })

        local left_type, left_errors =
            checker.checkimport("left.facade", loader)
        local right_type, right_errors =
            checker.checkimport("right.facade", loader)
        assert.truthy(left_type)
        assert.truthy(right_type)
        assert.equal(0, #left_errors)
        assert.equal(0, #right_errors)
        assert.is_nil(driver.imported["shared.owner"])

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match("logical owner 'shared.owner' has producer-dynamic " ..
            "exposures from conflicting providers", message, 1, true)
        assert.match(left_provider.archive, message, 1, true)
        assert.match(right_provider.archive, message, 1, true)
    end)

    it("rejects a producer-dynamic owner physically carried by another selected archive",
       function()
        local owner = owner_interface("bundle.owner", "Box")
        local facade = facade_interface(
            "facade.api", "Box", "bundle.owner.Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local facade_provider = cache_provider(context, "facade.a", {
            ["facade.api"] = facade,
        })
        local bundle_provider = cache_provider(context, "bundle.a", {
            ["bundle.api"] = types.Module("bundle.api", {}),
            ["bundle.owner"] = owner,
        })
        local loader = driver.defaultloader({}, { context = context })

        assert(checker.checkimport("facade.api", loader))
        assert(checker.checkimport("bundle.api", loader))
        assert.is_nil(driver.imported["bundle.owner"])

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match("logical owner 'bundle.owner' is required both directly",
            message, 1, true)
        assert.match(bundle_provider.archive, message, 1, true)
        assert.match(facade_provider.archive, message, 1, true)
    end)

    it("limits standalone protocol extraction to reachable selected keys",
       function()
        local selected_owner =
            owner_interface("reachable.owner", "Box")
        local unused_owner =
            owner_interface("unused.owner", "Box")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_provider(context, "reachable.a", {
            ["reachable.api"] = facade_interface(
                "reachable.api", "Box", "reachable.owner.Box"),
            ["reachable.owner"] = selected_owner,
            ["unused.facade"] = facade_interface(
                "unused.facade", "Box", "unused.owner.Box"),
            ["unused.owner"] = unused_owner,
        })
        local loader = driver.defaultloader({}, { context = context })

        assert(checker.checkimport("reachable.api", loader))
        assert(driver.finalize_resolver_context(context))
        assert.same({
            "reachable.api",
            "reachable.owner",
        }, driver.required_static_protocol_names(context, {
            ["reachable.owner"] = true,
        }))
    end)

    it("rejects overlapping physical membership without importing the sibling",
       function()
        local context =
            driver.new_resolver_context({ prefer_static = true })
        local left = cache_provider(context, "left.a", {
            ["left.api"] = types.Module("left.api", {}),
            ["shared.member"] = types.Module("shared.member", {}),
        })
        local right = cache_provider(context, "right.a", {
            ["right.api"] = types.Module("right.api", {}),
            ["shared.member"] = types.Module("shared.member", {}),
        })
        local loader = driver.defaultloader({}, { context = context })
        assert(checker.checkimport("left.api", loader))
        assert(checker.checkimport("right.api", loader))
        assert.is_nil(driver.imported["shared.member"])

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match("both contain logical module 'shared.member'",
            message, 1, true)
        assert.match(left.archive, message, 1, true)
        assert.match(right.archive, message, 1, true)
        assert.is_nil(driver.imported["shared.member"])
    end)

    it("rejects mangling collisions between ordinary dynamic imports",
       function()
        driver.imported["dynamic.a-b"] = {
            kind = "dynamic",
            filename = binary .. "/left.so",
            type = types.Module("dynamic.a-b", {}),
        }
        driver.imported["dynamic.a_b"] = {
            kind = "dynamic",
            filename = binary .. "/right.so",
            type = types.Module("dynamic.a_b", {}),
        }
        local context = driver.new_resolver_context()

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match("'dynamic.a-b'", message, 1, true)
        assert.match("'dynamic.a_b'", message, 1, true)
        assert.match("both use C symbol prefix 'dynamic_a_b'",
            message, 1, true)
    end)

    it("rejects mangling collisions across source and carried membership",
       function()
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_provider(context, "collision.a", {
            ["collision.a_b"] = types.Module("collision.a_b", {}),
        })
        ensure_directory(source .. "/collision")
        write_file(source .. "/collision/a-b.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { ["collision.a-b"] = true },
        })
        local source_ok, _, source_errors = loader("collision.a-b")
        assert.truthy(source_ok)
        assert.equal(0, #source_errors)
        assert(checker.checkimport("collision.a_b", loader))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.is_nil(finalized)
        local message = table.concat(final_errors, "\n")
        assert.match("logical modules", message, 1, true)
        assert.match("'collision.a-b'", message, 1, true)
        assert.match("'collision.a_b'", message, 1, true)
        assert.match("both use C symbol prefix 'collision_a_b'",
            message, 1, true)
    end)
end)

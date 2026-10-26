local incremental = require "titan-compiler.incremental"
local objectmetadata = require "titan-compiler.objectmetadata"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local sha256 = require "titan-compiler.sha256"
local cpreamble = require "titan-compiler.cpreamble"
local cpp = require "c-parser.cpp"

local function context(files)
    local dirs = { ["/"] = true }
    for path in pairs(files) do
        local parent = path:match("^(.*)/[^/]+$")
        while parent and parent ~= "" do
            dirs[parent] = true
            parent = parent:match("^(.*)/[^/]+$")
        end
    end
    local io = { reads = {}, commands = {}, writes = {}, aliases = {}, clock = 1 }
    function io:cwd() return "/" end
    function io:realpath(path)
        path = self.aliases[path] or path
        if files[path] ~= nil or dirs[path] then return path end
        return nil, "missing " .. path
    end
    function io:stat(path)
        path = self.aliases[path] or path
        if dirs[path] then return { kind = "directory" } end
        if files[path] == nil then return nil end
        return { kind = "file", size = #files[path], mode = 0x81ed,
            device = 1, inode = 2, modified_seconds = 1, modified_nanoseconds = 0,
            changed_seconds = self.clock, changed_nanoseconds = 0, time_precision = "coarse" }
    end
    function io:lstat(path) return self:stat(path) end
    function io:readable(path) return files[self.aliases[path] or path] ~= nil end
    function io:read_file(path)
        self.reads[path] = (self.reads[path] or 0) + 1
        return files[self.aliases[path] or path], "missing " .. path
    end
    function io:write_file(path, bytes)
        self.writes[path] = (self.writes[path] or 0) + 1
        files[path] = bytes
        return true
    end
    function io:list(directory)
        if not dirs[directory] then return nil, "missing directory " .. directory end
        local entries, seen = {}, {}
        for path in pairs(files) do
            if path:sub(1, #directory + 1) == directory .. "/" then
                local name = path:sub(#directory + 2):match("^[^/]+")
                if not seen[name] then entries[#entries + 1], seen[name] = name, true end
            end
        end
        return entries
    end
    function io:mkdir(path) dirs[path] = true; return true end
    function io:tmpname() files["/temporary.d"] = ""; return "/temporary.d" end
    function io:unlink(path) files[path] = nil; return true end
    function io:yield() self.yields = (self.yields or 0) + 1 end
    function io:run(argv)
        self.commands[#self.commands + 1] = argv
        local dep
        for index, arg in ipairs(argv) do if arg == "-MF" then dep = argv[index + 1] end end
        if dep then
            files[dep] = "titan-preamble: " .. argv[#argv] .. " /sdk/common.h\n"
            return { ok = true, output = self.expanded or "#define NATIVE_OPTION 1\n" }
        end
        error("unexpected native command")
    end
    local ctx = { io = io, cache_adapter = { sha256_binary = sha256.binary } }
    return ctx, files
end

local function configuration()
    return { compiler = "compiler", preamble = "preamble", toolchain = "toolchain",
        options = "options", digest = "configuration" }
end

local function certificate()
    return { configuration = configuration(), layout = "flat",
        sources = { { path = "/src/main.titan", sha256 = sha256.hex("source") } },
        stem = "/out/main", codegen = { c_parts = 1, split_threshold = 0, test_flags = false },
        imports = {}, owners = {}, bindings = {}, providers = {},
        interface = { public = "public", source = "source-private" }, object_identity = "recipe" }
end

local function record(cert)
    return { type = { name = "main" }, object_metadata = { certificate = cert or certificate(),
        parts_version = 1, parts = { { index = 0, c_suffix = ".c", object_suffix = ".o" } } } }
end

local function plan(digests, linked, providers)
    return {
        digest = function(name, view)
            local value = digests[name]
            if value == "pending" then return nil, "pending" end
            if type(value) == "table" then return value[view], "unavailable" end
            return value, "unavailable"
        end,
        linked = function(name) return linked and linked[name] or false end,
        provider_file = function(name) return providers and providers[name] end,
    }
end

local function source_entry(name)
    local modtype = types.Module(name, {}, {})
    modtype._source = true
    return { kind = "source", type = modtype, filename = "/src/main.titan",
        source_files = { "/src/main.titan" }, source_manifest = "private surface",
        c_header_dependencies = {}, deps = {}, declared_registry = {} }
end

describe("incremental certificate identities", function()
    it("canonicalizes maps without losing array order types or boundaries", function()
        local ctx = context({})
        local a = incremental.digest(ctx, "test", { z = 1, a = { false, "" } })
        assert.equal(a, incremental.digest(ctx, "test", { a = { false, "" }, z = 1 }))
        assert.is_not.equal(a, incremental.digest(ctx, "other", { a = { false, "" }, z = 1 }))
        assert.is_not.equal(incremental.digest(ctx, "test", { "ab", "c" }),
            incremental.digest(ctx, "test", { "a", "bc" }))
        assert.is_not.equal(incremental.digest(ctx, "test", { 1, 2 }),
            incremental.digest(ctx, "test", { 2, 1 }))
        assert.is_not.equal(incremental.digest(ctx, "test", false), incremental.digest(ctx, "test", nil))
        assert.is_not.equal(incremental.digest(ctx, "test", 1), incremental.digest(ctx, "test", "1"))
    end)

    it("rejects cyclic certificate values", function()
        local ctx = context({})
        local cyclic = {}; cyclic.self = cyclic
        assert.has_error(function() incremental.digest(ctx, "test", cyclic) end,
            "cyclic certificate value")
    end)

    it("hashes each canonical file once and retains the exact source bytes", function()
        local ctx = context({ ["/src/main.titan"] = "source" })
        ctx.io.aliases["/alias.titan"] = "/src/main.titan"
        local source = { kind = "flat", main = "/src/main.titan", files = { "/src/main.titan" } }
        local first = incremental.source_certificate(ctx, source)
        assert.same(first, incremental.source_certificate(ctx, source))
        assert.equal(first.sources[1].sha256, incremental.file_digest(ctx, "/alias.titan"))
        assert.equal("source", source.certified_contents["/src/main.titan"])
        assert.is_nil(source.contents)
        local counters = incremental.counters(ctx)
        assert.equal(1, counters.file_hashes)
        assert.equal(1, counters.file_reads)
        assert.equal(6, counters.file_bytes)
        assert.equal(1, counters.files["/src/main.titan"].hashes)
        assert.has_error(function() incremental.file_digest(ctx, "/src/main.titan", "edited") end,
            "/src/main.titan: file changed during build")
    end)

    it("retires a replaced owned output memo without resetting its counters", function()
        local ctx, files = context({ ["/out/main.o"] = "old" })
        local old = incremental.file_digest(ctx, "/out/main.o")
        files["/out/main.o"] = "new"
        incremental.invalidate_file(ctx, "/out/main.o")
        assert.is_not.equal(old, incremental.file_digest(ctx, "/out/main.o"))
        assert.equal(2, incremental.counters(ctx).file_hashes)
    end)

    it("detects changed-read observations and propagates non-string cancellation", function()
        local ctx = context({ ["/src/main.titan"] = "source" })
        local read = ctx.io.read_file
        function ctx.io:read_file(path) self.clock = self.clock + 1; return read(self, path) end
        assert.has_error(function() incremental.file_digest(ctx, "/src/main.titan") end,
            "/src/main.titan: file changed while it was read")
        local cancelled = {}
        function ctx.io:read_file() error(cancelled, 0) end
        local ok, err = pcall(incremental.file_digest, ctx, "/src/main.titan")
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)

    it("uses stored producer digests without reconstructing a restored AST", function()
        local ctx = context({})
        local entry = source_entry("main")
        local pending, why = incremental.interface_digest(ctx, entry, "public")
        assert.is_nil(pending); assert.equal("pending", why)
        entry.interface_digests = { public = "stored-public", source = "stored-private" }
        assert.equal("stored-public", incremental.interface_digest(ctx, entry, "public"))
        assert.equal("stored-private", incremental.interface_digest(ctx, entry, "source"))
        entry.interface_digests = nil
        entry.object_metadata = { certificate = { interface = { public = "restored", source = "private" } } }
        assert.equal("restored", incremental.interface_digest(ctx, entry, "public"))
    end)

    it("covers producer layout private surface and copied helper bodies separately", function()
        local ctx = context({})
        local entry = source_entry("main")
        local recipe = { prefix = "/* helper */", source_headers = { "dependency" }, body = "return 1;" }
        local first = incremental.producer_digests(ctx, entry, "layouts", recipe)
        entry.source_manifest = "changed private surface"
        local private = incremental.producer_digests(ctx, entry, "layouts", recipe)
        assert.equal(first.public, private.public)
        assert.is_not.equal(first.source, private.source)
        local layout = incremental.producer_digests(ctx, entry, "changed layouts", recipe)
        assert.is_not.equal(first.public, layout.public)
        recipe.body = "return 2;"
        local helper = incremental.producer_digests(ctx, entry, "layouts", recipe)
        assert.is_not.equal(private.public, helper.public)
    end)

    it("memoizes binary interfaces by logical module rather than combined-provider bytes", function()
        local ctx = context({ ["/sdk/titan.so"] = "provider bytes" })
        local function binary(name, layouts)
            local modtype = types.Module(name, {}, {})
            modtype.file = "/sdk/titan.so"
            return { kind = "binary", type = modtype, filename = "/sdk/titan.so", layouts = layouts }
        end
        local a, b = binary("a", "a-layout"), binary("b", "b-layout")
        local before = incremental.interface_digest(ctx, a, "public")
        assert.is_not.equal(before, incremental.interface_digest(ctx, b, "public"))
        b.layouts = "changed b-layout"
        assert.equal(before, incremental.interface_digest(ctx, a, "public"))
        local changed = context({})
        assert.is_not.equal(incremental.interface_digest(ctx, binary("b", "b-layout")),
            incremental.interface_digest(changed, b))
        assert.equal(0, incremental.counters(ctx).file_hashes)
    end)

    it("records contextual owners from both usage and binding keys", function()
        local ctx = context({ ["/src/main.titan"] = "source" })
        ctx.incremental_configuration = configuration()
        local entry = source_entry("main")
        entry.interface_digests = { public = "self-public", source = "self-private" }
        local native = { layouts = "layout", imports = { { name = "direct", source_required = true } },
            bindings = { direct = "direct", owner = "global", main = "direct" }, providers = {} }
        local source = { kind = "flat", main = entry.filename, files = entry.source_files }
        local cert = incremental.make_certificate(ctx, entry, native, {
            source = incremental.source_certificate(ctx, source),
            stem = "/out/main", codegen = certificate().codegen,
            plan = plan({ direct = { source = "direct-private" }, owner = "owner-public", used = "used-public" }),
            binary_usage = { main = true, direct = true, used = true },
            generated_parts = { { index = 0, code = "generated C" } }, private_header = "private C" })
        assert.same({ { name = "owner", interface = "owner-public" },
            { name = "used", interface = "used-public" } }, cert.owners)
        assert.equal("source", cert.imports[1].view)
        assert.equal("direct-private", cert.imports[1].interface)
        assert.is_nil(native.imports[1].interface)
        assert.is_string(cert.object_identity)
    end)
end)

describe("incremental configuration", function()
    local function configured()
        local ctx, files = context({ ["/compiler/titan-compiler/driver.lua"] = "driver",
            ["/compiler/titan-compiler/checker/entry.lua"] = "checker",
            ["/compiler/titan-compiler/coder/generate.lua"] = "coder",
            ["/compiler/c-parser/cpp.lua"] = "parser", ["/real/titanc"] = "real frontend",
            ["/bin/titanc"] = "wrapper", ["/sdk/common.h"] = "header", ["/tool/cc"] = "tool" })
        ctx.incremental_options = { compiler_root = "/compiler", frontend = "/real/titanc",
            preamble_path = "/out/.titan/preamble.c", compile_prefix = { "/tool/cc", "-O2" },
            toolchain_descriptor = { compiler_argv = { "/tool/cc" },
                preprocessor_identity = "macros", banner = "clang vendor target", stage_tools = {} },
            build_profile = "validation", emit_line_directives = true, titan_root = "/sdk" }
        return ctx, files
    end

    it("computes one invocation certificate and inventories the real frontend not its wrapper", function()
        local ctx = configured()
        local cert = incremental.configuration(ctx)
        assert.equal(cert, incremental.configuration(ctx))
        assert.equal(1, #ctx.io.commands)
        assert.equal(1, ctx.io.reads["/real/titanc"])
        assert.is_nil(ctx.io.reads["/bin/titanc"])
        assert.is_nil(ctx.io.reads["/tool/cc"])
        for _, file in pairs(incremental.counters(ctx).files) do assert.equal(1, file.hashes) end
        assert.equal(cpreamble.certification_includes, ctx.io.writes["/out/.titan/preamble.c"] and
            select(2, incremental.file_digest(ctx, "/out/.titan/preamble.c")))
    end)

    it("verifies the worker compiler component without native probes", function()
        local ctx = configured()
        local compiler = assert(incremental.compiler_component(ctx))
        assert.same({}, ctx.io.commands)
        assert.equal(compiler, incremental.configuration(ctx).compiler)
        assert.equal(1, #ctx.io.commands)
    end)

    it("separates compile policy from resolution and link-only settings", function()
        local first, second, third = configured(), configured(), configured()
        second.incremental_options.source_first = true
        second.incremental_options.static = true
        second.incremental_options.test = true
        second.incremental_options.jobs = 8
        second.incremental_options.ldflags = { "-lother" }
        third.incremental_options.compile_prefix[2] = "-O3"
        local before, unchanged = incremental.configuration(first), incremental.configuration(second)
        assert.equal(before.digest, unchanged.digest)
        assert.is_not.equal(before.options, incremental.configuration(third).options)
    end)

    it("certifies explicit wrappers and named compiler stages once per configuration", function()
        local ctx = context({ ["/tool/ccache"] = "wrapper", ["/tool/gcc"] = "driver",
            ["/tool/cc1"] = "compiler stage", ["/tool/as"] = "assembler" })
        function ctx.io:run(argv)
            self.commands[#self.commands + 1] = argv
            local name = argv[#argv]:match("^-print%-prog%-name=(.*)$")
            assert.is_not_nil(name)
            return { ok = true, output = "/tool/" .. name .. "\n" }
        end
        local descriptor = { compiler_argv = { "/tool/ccache", "/tool/gcc" },
            preprocessor_identity = "macros", banner = "gcc version vendor" }
        local digest, details = incremental.toolchain_identity(ctx, descriptor)
        assert.equal(4, #details.tools)
        assert.equal(digest, incremental.toolchain_identity(ctx, descriptor))
        assert.equal(2, #ctx.io.commands)
        assert.equal(0, incremental.counters(ctx).file_hashes)
    end)

    it("keeps preprocessed presence-query state in addition to positive dependencies", function()
        local first, second = configured(), configured()
        second.io.expanded = "#define OPTIONAL_HEADER_PRESENT 1\n"
        local before, after = incremental.configuration(first), incremental.configuration(second)
        assert.equal(before.compiler, after.compiler)
        assert.equal(before.toolchain, after.toolchain)
        assert.is_not.equal(before.preamble, after.preamble)
    end)

    it("includes physical tool replacement without hashing executable contents", function()
        local first, second = configured(), configured()
        second.io.clock = 2
        local before, after = incremental.configuration(first), incremental.configuration(second)
        assert.is_not.equal(before.toolchain, after.toolchain)
        assert.equal(before.compiler, after.compiler)
        assert.is_nil(first.io.reads["/tool/cc"])
        assert.is_nil(second.io.reads["/tool/cc"])
    end)

    it("reports inventory errors and preserves cancellation values", function()
        local ctx, files = configured()
        files["/real/titanc"] = nil
        local ok, err = pcall(incremental.configuration, ctx)
        assert.is_false(ok)
        assert.matches("cannot certify compiler configuration:", err, 1, true)
        local cancelled = {}
        local other = configured()
        function other.io:list() error(cancelled, 0) end
        local success, failure = pcall(incremental.configuration, other)
        assert.is_false(success); assert.equal(cancelled, failure)
    end)
end)

describe("incremental dependency verdicts", function()
    local function imported(source_required)
        local cert = certificate()
        cert.imports = { { name = "producer", source_required = source_required == true,
            view = source_required and "source" or "public", interface = "same" } }
        cert.bindings = { producer = "handle" }
        cert.providers = { producer = "/sdk/producer.so" }
        return record(cert)
    end

    it("accepts an unchanged semantic interface despite a rebuilt producer", function()
        assert.same({ status = "hit" }, incremental.verdict(imported(),
            plan({ producer = "same" }, nil, { producer = "/sdk/producer.so" })))
    end)

    it("distinguishes unavailable changed public and changed source interfaces", function()
        assert.same({ status = "miss", reason = "dependency-unavailable", detail = "producer" },
            incremental.verdict(imported(), plan({})))
        assert.same({ status = "miss", reason = "import-interface", detail = "producer (public)" },
            incremental.verdict(imported(), plan({ producer = "changed" })))
        assert.same({ status = "miss", reason = "import-interface", detail = "producer (source)" },
            incremental.verdict(imported(true), plan({ producer = "changed" })))
    end)

    it("returns deterministic pending owners and imports without duplicate names", function()
        local saved = imported()
        saved.object_metadata.certificate.owners = { { name = "contextual", interface = "old" } }
        assert.same({ status = "pending", names = { "contextual", "producer" } },
            incremental.verdict(saved, plan({ producer = "pending", contextual = "pending" }, nil,
                { producer = "/sdk/producer.so" })))
    end)

    it("checks contextual owners not present in direct imports", function()
        local saved = record()
        saved.object_metadata.certificate.owners = { { name = "contextual", interface = "same" } }
        saved.object_metadata.certificate.bindings = { contextual = "global" }
        assert.equal("owner-interface", incremental.verdict(saved, plan({ contextual = "changed" })).reason)
        assert.equal("owner-binding", incremental.verdict(saved,
            plan({ contextual = "same" }, { contextual = true })).reason)
    end)

    it("compares direct handle global and exact provider filename bindings", function()
        local current = { producer = "same" }
        assert.equal("import-binding", incremental.verdict(imported(),
            plan(current, { producer = true })).reason)
        assert.equal("import-binding", incremental.verdict(imported(),
            plan(current, nil, { producer = "/sdk/replacement.so" })).reason)
        local saved = imported()
        saved.object_metadata.certificate.bindings.producer = "global"
        assert.equal("import-binding", incremental.verdict(saved,
            plan(current, nil, { producer = "/sdk/producer.so" })).reason)
    end)

    it("certifies self as direct without an owner-interface dependency", function()
        local saved = record()
        saved.object_metadata.certificate.bindings.main = "direct"
        assert.equal("hit", incremental.verdict(saved, {}).status)
        saved.object_metadata.certificate.bindings.main = "global"
        local result = incremental.verdict(saved, {})
        assert.equal("import-binding", result.reason)
        assert.equal("main: global -> direct", result.detail)
    end)

    it("retains both views when a module is imported ordinarily and explicitly", function()
        local saved = imported()
        local imports = saved.object_metadata.certificate.imports
        imports[2] = { name = "producer", source_required = true, view = "source", interface = "private" }
        assert.equal("hit", incremental.verdict(saved,
            plan({ producer = { public = "same", source = "private" } }, nil,
                { producer = "/sdk/producer.so" })).status)
    end)

    it("rejects missing certificates before consulting a plan", function()
        assert.equal("record-schema", incremental.verdict({ object_metadata = {} }, {}).reason)
    end)
end)

describe("incremental local certification", function()
    local read, scan, revalidate
    before_each(function()
        read, scan, revalidate = objectmetadata.read, staticmetadata.scan_bytes, cpp.revalidate_header_input
    end)
    after_each(function()
        objectmetadata.read, staticmetadata.scan_bytes, cpp.revalidate_header_input = read, scan, revalidate
    end)
    local function fixture()
        local ctx, files = context({ ["/out/main.o"] = "object", ["/out/main.c"] = "generated",
            ["/src/main.titan"] = "source" })
        ctx.incremental_configuration = configuration()
        ctx.incremental_options = { stem = function() return "/out/main" end,
            codegen_options = function() return certificate().codegen end }
        local saved = record()
        objectmetadata.read = function() return saved end
        staticmetadata.scan_bytes = function() return { kind = "object", fingerprint = {} } end
        local source = { kind = "flat", main = "/src/main.titan", files = { "/src/main.titan" } }
        return ctx, saved, source, files
    end

    it("returns the primary and ordered validated object inventory without native commands", function()
        local ctx, _, source = fixture()
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("hit", result.status)
        assert.equal("/out/main.o", result.object)
        assert.same({ "/out/main.o" }, result.objects)
        assert.same({}, result.imports)
        assert.same({}, ctx.io.commands)
    end)

    it("retains imports across configuration and codegen misses only when own sources match", function()
        local ctx, saved, source = fixture()
        saved.object_metadata.certificate.configuration.compiler = "old"
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("configuration", result.reason); assert.equal("compiler", result.detail)
        assert.same({}, result.imports)
        local other, other_saved, other_source = fixture()
        other_saved.object_metadata.certificate.codegen.test_flags = true
        local changed = incremental.certify_local(other, "main", other_source)
        assert.equal("codegen-options", changed.reason); assert.equal("test_flags", changed.detail)
        assert.same({}, changed.imports)
    end)

    it("detects same-time source content edits and exact folder addition and removal", function()
        local ctx, _, source, files = fixture()
        files["/src/main.titan"] = "edited"
        local changed = incremental.certify_local(ctx, "main", source)
        assert.equal("source-content", changed.reason); assert.equal("/src/main.titan", changed.detail)
        assert.is_nil(changed.imports)
        local added, _, folder, more = fixture()
        more["/src/extra.titan"] = "extra"
        folder.kind, folder.files[2] = "folder", "/src/extra.titan"
        local addition = incremental.certify_local(added, "main", folder)
        assert.equal("source-set", addition.reason); assert.equal("added /src/extra.titan", addition.detail)
        local removed, saved, single = fixture()
        saved.object_metadata.certificate.sources[2] = { path = "/src/old.titan", sha256 = "old" }
        local removal = incremental.certify_local(removed, "main", single)
        assert.equal("source-set", removal.reason); assert.equal("removed /src/old.titan", removal.detail)
    end)

    it("classifies envelope absence and output movement", function()
        local ctx, _, source, files = fixture()
        files["/out/main.o"] = nil
        assert.equal("no-object", incremental.certify_local(ctx, "main", source).reason)
        local old, _, old_source = fixture()
        objectmetadata.read = function() return nil, "old schema", "record-schema" end
        assert.equal("record-schema", incremental.certify_local(old, "main", old_source).reason)
        local moved, saved, moved_source = fixture()
        saved.object_metadata.certificate.stem = "/old/main"
        assert.equal("output-moved", incremental.certify_local(moved, "main", moved_source).reason)
    end)

    it("checks descriptor search inputs before restoring any graph", function()
        local ctx, saved, source = fixture()
        saved.ffi_header_descriptor = { search_inputs = {
            { kind = "search", path = "/sdk/header.h", identity = "old" } } }
        local calls = 0
        cpp.revalidate_header_input = function(input)
            calls = calls + 1
            return input, nil, true, "candidate"
        end
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("c-input", result.reason); assert.equal("/sdk/header.h: candidate", result.detail)
        assert.equal(1, calls)
        assert.same({}, result.imports)
        assert.is_nil(saved.compiled)
    end)

    it("checks split-part and coverage artifact completeness", function()
        local ctx, saved, source, files = fixture()
        local native = saved.object_metadata
        native.parts[2] = { index = 1, c_suffix = ".part1.c", object_suffix = ".part1.o" }
        native.private_header = ".priv.h"
        files["/out/main.part1.c"], files["/out/main.priv.h"] = "generated part", "private header"
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", result.reason)
        assert.matches("/out/main.part1.o", result.detail, 1, true)
        local covered, cover_record, cover_source, cover_files = fixture()
        cover_record.object_metadata.coverage = { enabled = true, files = { "/out/main.c" } }
        local missing = incremental.certify_local(covered, "main", cover_source)
        assert.equal("coverage-artifacts", missing.reason)
        assert.equal("/out/main.gcno", missing.detail)
        cover_files["/out/main.gcno"] = "coverage notes"
        assert.equal("hit", incremental.certify_local(covered, "main", cover_source).status)
    end)

    it("requires the recorded generated C and private-header companions", function()
        local ctx, saved, source, files = fixture()
        local native = saved.object_metadata
        native.parts[2] = { index = 1, c_suffix = ".part1.c", object_suffix = ".part1.o" }
        native.private_header = ".priv.h"
        files["/out/main.part1.o"] = "part object"
        local missing_c = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", missing_c.reason)
        assert.matches("/out/main.part1.c", missing_c.detail, 1, true)
        files["/out/main.part1.c"] = "generated part"
        local missing_h = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", missing_h.reason)
        assert.matches("/out/main.priv.h", missing_h.detail, 1, true)
    end)

    it("shares source object and C-input hash memos across certifications", function()
        local ctx, saved, source, files = fixture()
        files["/sdk/header.h"] = "header"
        saved.c_header_dependencies = { { kind = "file", path = "/sdk/header.h", identity = "header" } }
        saved.ffi_header_descriptor = { search_inputs = saved.c_header_dependencies }
        local passes = 0
        cpp.revalidate_header_input = function(input, opts)
            if not opts.header_validation[input.path] then
                opts.header_validation[input.path] = true
                passes = passes + 1
                opts.file_digest(input.path, files[input.path])
            end
            return input, nil, false
        end
        assert.equal("hit", incremental.certify_local(ctx, "main", source).status)
        assert.equal("hit", incremental.certify_local(ctx, "main", source).status)
        assert.equal(1, passes)
        for _, file in pairs(incremental.counters(ctx).files) do assert.equal(1, file.hashes) end
    end)

    it("rereads publication inputs independently and counts that work separately", function()
        local ctx, saved, source, files = fixture()
        assert.equal("hit", incremental.certify_local(ctx, "main", source).status)
        local hashes = incremental.counters(ctx).file_hashes
        assert.equal("hit", incremental.revalidate_record(ctx, "main", source, saved).status)
        files["/src/main.titan"] = "edited"
        local result = incremental.revalidate_record(ctx, "main", source, saved)
        assert.equal("source-content", result.reason)
        local counters = incremental.counters(ctx)
        assert.equal(hashes, counters.file_hashes)
        assert.equal(2, counters.revalidation.passes)
        assert.equal(2, counters.revalidation.file_hashes)
    end)

    it("propagates non-string cancellation from local reads", function()
        local ctx, _, source = fixture()
        local cancelled = {}
        function ctx.io:read_file() error(cancelled, 0) end
        local ok, err = pcall(incremental.certify_local, ctx, "main", source)
        assert.is_false(ok); assert.equal(cancelled, err)
    end)
end)

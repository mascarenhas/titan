local incremental = require "titan-compiler.incremental"
local objectmetadata = require "titan-compiler.objectmetadata"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local sha256 = require "titan-compiler.sha256"
local cpreamble = require "titan-compiler.cpreamble"
local cpp = require "c-parser.cpp"
local version = require "titan-compiler.version"
local platform = require "titan-compiler.platform"

local function fixture_path(path)
    return platform.windows and "C:" .. path or path
end

local function native_tool(name)
    return fixture_path("/tool/" .. name .. (platform.windows and ".exe" or ""))
end

local function context(files)
    local root = fixture_path("/")
    local dirs = { [root] = true }
    for path in pairs(files) do
        local parent = path:match("^(.*)/[^/]+$")
        while parent and parent ~= "" do
            dirs[parent] = true
            parent = parent:match("^(.*)/[^/]+$")
        end
    end
    local io = { reads = {}, commands = {}, writes = {}, aliases = {}, clock = 1 }
    function io:cwd() return root end
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
    function io:executable(path) return files[self.aliases[path] or path] ~= nil end
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
    function io:tmpname()
        local filename = root .. "temporary.d"
        files[filename] = ""
        return filename
    end
    function io:unlink(path) files[path] = nil; return true end
    function io:rename(from, to)
        files[to], files[from] = files[from], nil
        self.renames = (self.renames or 0) + 1
        return true
    end
    function io:yield() self.yields = (self.yields or 0) + 1 end
    function io:run(argv)
        self.commands[#self.commands + 1] = argv
        local dep
        for index, arg in ipairs(argv) do if arg == "-MF" then dep = argv[index + 1] end end
        if dep then
            local source, header = argv[#argv], root .. "sdk/common.h"
            if platform.windows then
                source, header = source:gsub(":", "\\:"), header:gsub(":", "\\:")
            end
            files[dep] = "titan-preamble: " .. source .. " " .. header .. "\n"
            return { ok = true, output = self.expanded or "#define NATIVE_OPTION 1\n" }
        end
        error("unexpected native command")
    end
    local ctx = { io = io, cache_adapter = { sha256_binary = sha256.binary } }
    return ctx, files
end

local function native_context(files)
    local ctx = context(files)
    function ctx.io:executable_search_cwd() return false end
    return ctx, files
end

local function precise_context(files)
    local ctx = context(files)
    local stat = ctx.io.stat
    ctx.io.observation_changes = {}
    function ctx.io:stat(path)
        local value, err = stat(self, path)
        if not value then return nil, err end
        value.precision, value.dev, value.ino = "ns", "1", self.aliases[path] or path
        value.size, value.mode = value.size or 0, value.mode or 0
        value.mtime_ns, value.ctime_ns = 1000000000, self.clock * 1000000000
        for key, changed in pairs(self.observation_changes[path] or {}) do value[key] = changed end
        return value
    end
    return ctx
end

local function configuration()
    return { compiler = "compiler", preamble = "preamble", toolchain = "toolchain",
        options = "options", digest = "configuration" }
end

local function certificate()
    return { configuration = configuration(), layout = "flat",
        sources = { { path = fixture_path("/src/main.titan"), sha256 = sha256.hex("source") } },
        stem = fixture_path("/out/main"), codegen = { c_parts = 1, split_threshold = 0, test_flags = false },
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
    return { kind = "source", type = modtype, filename = fixture_path("/src/main.titan"),
        source_files = { fixture_path("/src/main.titan") }, source_manifest = "private surface",
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
        local ctx = context({ [fixture_path("/src/main.titan")] = "source" })
        ctx.io.aliases[fixture_path("/alias.titan")] = fixture_path("/src/main.titan")
        local source = { kind = "flat", main = fixture_path("/src/main.titan"),
            files = { fixture_path("/src/main.titan") } }
        local first = incremental.source_certificate(ctx, source)
        assert.same(first, incremental.source_certificate(ctx, source))
        assert.equal(first.sources[1].sha256, incremental.file_digest(ctx, fixture_path("/alias.titan")))
        assert.equal("source", source.certified_contents[fixture_path("/src/main.titan")])
        assert.is_nil(source.contents)
        local counters = incremental.counters(ctx)
        assert.equal(1, counters.file_hashes)
        assert.equal(1, counters.file_reads)
        assert.equal(6, counters.file_bytes)
        assert.equal(1, counters.files[fixture_path("/src/main.titan")].hashes)
        assert.has_error(function() incremental.file_digest(ctx, fixture_path("/src/main.titan"), "edited") end,
            fixture_path("/src/main.titan") .. ": file changed during build")
    end)

    it("retires a replaced owned output memo without resetting its counters", function()
        local ctx, files = context({ [fixture_path("/out/main.o")] = "old" })
        local old = incremental.file_digest(ctx, fixture_path("/out/main.o"))
        files[fixture_path("/out/main.o")] = "new"
        incremental.invalidate_file(ctx, fixture_path("/out/main.o"))
        assert.is_not.equal(old, incremental.file_digest(ctx, fixture_path("/out/main.o")))
        assert.equal(2, incremental.counters(ctx).file_hashes)
    end)

    it("detects changed-read observations and propagates non-string cancellation", function()
        local ctx = context({ [fixture_path("/src/main.titan")] = "source" })
        local read = ctx.io.read_file
        function ctx.io:read_file(path) self.clock = self.clock + 1; return read(self, path) end
        assert.has_error(function() incremental.file_digest(ctx, fixture_path("/src/main.titan")) end,
            fixture_path("/src/main.titan") .. ": file changed while it was read")
        local cancelled = {}
        function ctx.io:read_file() error(cancelled, 0) end
        local ok, err = pcall(incremental.file_digest, ctx, fixture_path("/src/main.titan"))
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)

    it("preserves failed-read diagnostics and cancellation values", function()
        local path = fixture_path("/src/main.titan")
        local message = path .. ": forced read failure"
        for _, reader in ipairs({ incremental.file_digest, incremental.file_contents }) do
            for _, failure in ipairs({ "nil", "false" }) do
                local ctx = context({ [path] = "source" })
                function ctx.io:read_file()
                    if failure == "false" then return false, message end
                    return nil, message
                end
                assert.has_error(function() reader(ctx, path) end, message)
                assert.equal(0, incremental.counters(ctx).file_hashes)
                assert.equal(0, incremental.counters(ctx).file_reads)
            end
        end
        local ctx = context({ [path] = "source" })
        local cancelled = {}
        function ctx.io:read_file() return false, cancelled end
        local ok, err = pcall(incremental.file_contents, ctx, path)
        assert.is_false(ok)
        assert.equal(cancelled, err)
        assert.equal("", incremental.file_contents(context({ [path] = "" }), path))
    end)

    describe("streamed digests", function()
        local support = require "titan"
        local THRESHOLD = incremental.STREAM_THRESHOLD_BYTES
        local large_path, small_path = fixture_path("/out/program"), fixture_path("/out/small.o")
        local large = ("titan\0"):rep(THRESHOLD // 6 + 2):sub(1, THRESHOLD + 7)
        local small = ("small\0"):rep(THRESHOLD // 6 + 1):sub(1, THRESHOLD)

        -- The native stream and an absorption-counting strategy over
        -- in-memory files, feeding bounded chunks.
        local function streaming(files, precise)
            if type(support._sha256_stream) ~= "function" then
                pending("native _sha256_stream requires a reinstalled runtime")
                return nil
            end
            local ctx = precise and precise_context(files) or context(files)
            ctx.cache_adapter = { sha256_binary = support._sha256_binary,
                sha256_stream = support._sha256_stream }
            ctx.io.absorbed = {}
            function ctx.io:absorb_file(path, stream)
                local bytes = files[self.aliases[path] or path]
                if bytes == nil then return nil, "missing " .. path end
                self.absorbed[path] = (self.absorbed[path] or 0) + 1
                for first = 1, #bytes, 65536 do stream:update(bytes:sub(first, first + 65535)) end
                return #bytes
            end
            return ctx
        end
        local function native_hex(bytes) return sha256.to_hex(support._sha256_binary(bytes)) end

        it("hashes a large digest-only file through the stream without retaining it", function()
            local ctx = streaming({ [large_path] = large, [small_path] = small }, true)
            if not ctx then return end
            local digest, bytes = incremental.file_digest(ctx, large_path)
            assert.equal(native_hex(large), digest)
            assert.is_nil(bytes)
            assert.is_nil(ctx.io.reads[large_path])
            assert.equal(1, ctx.io.absorbed[large_path])
            local counters = incremental.counters(ctx)
            assert.equal(1, counters.file_reads)
            assert.equal(1, counters.file_hashes)
            assert.equal(#large, counters.file_bytes)
            assert.equal(digest, (incremental.file_digest(ctx, large_path)))
            assert.equal(1, ctx.io.absorbed[large_path])
            -- Byte demand reads the file once and verifies it against the digest.
            assert.equal(large, incremental.file_contents(ctx, large_path))
            assert.equal(1, ctx.io.reads[large_path])
            assert.equal(1, incremental.counters(ctx).file_hashes)

            -- A file of at most the threshold keeps its single whole read.
            local small_digest, small_bytes = incremental.file_digest(ctx, small_path)
            assert.equal(native_hex(small), small_digest)
            assert.equal(small, small_bytes)
            assert.equal(1, ctx.io.reads[small_path])
            assert.is_nil(ctx.io.absorbed[small_path])
        end)

        it("reads whole files without the native stream or a streaming strategy", function()
            local ctx = streaming({ [large_path] = large })
            if not ctx then return end
            ctx.io.absorb_file = nil
            assert.equal(native_hex(large), (incremental.file_digest(ctx, large_path)))
            assert.equal(1, ctx.io.reads[large_path])
            ctx = streaming({ [large_path] = large })
            ctx.cache_adapter.sha256_stream = nil
            assert.equal(native_hex(large), (incremental.file_digest(ctx, large_path)))
            assert.equal(1, ctx.io.reads[large_path])
            assert.is_nil(ctx.io.absorbed[large_path])
        end)

        it("rejects a file that changes while it is streamed and keeps cancellation", function()
            local files = { [large_path] = large }
            local ctx = streaming(files, true)
            if not ctx then return end
            local absorb_file = ctx.io.absorb_file
            function ctx.io:absorb_file(...) self.clock = self.clock + 1; return absorb_file(self, ...) end
            assert.has_error(function() incremental.file_digest(ctx, large_path) end,
                large_path .. ": file changed while it was read")
            ctx = streaming(files, true)
            function ctx.io:absorb_file(_, stream)
                stream:update(large:sub(1, THRESHOLD))
                return THRESHOLD
            end
            assert.has_error(function() incremental.file_digest(ctx, large_path) end,
                large_path .. ": file changed while it was read")
            ctx = streaming(files, true)
            function ctx.io:absorb_file() return nil, large_path .. ": forced read failure" end
            assert.has_error(function() incremental.file_digest(ctx, large_path) end,
                large_path .. ": forced read failure")
            assert.equal(0, incremental.counters(ctx).file_hashes)
            local cancelled = {}
            ctx = streaming(files, true)
            function ctx.io:absorb_file(_, stream) stream:update("x"); error(cancelled, 0) end
            local ok, err = pcall(incremental.file_digest, ctx, large_path)
            assert.is_false(ok)
            assert.equal(cancelled, err)
        end)

        it("verifies a coarse streamed digest by content before serving bytes", function()
            local files = { [large_path] = large }
            local ctx = streaming(files)
            if not ctx then return end
            local digest, _, observed = incremental.file_digest(ctx, large_path)
            assert.is_nil(observed)
            assert.equal(large, incremental.file_contents(ctx, large_path))
            ctx = streaming(files)
            assert.equal(digest, (incremental.file_digest(ctx, large_path)))
            files[large_path] = large:sub(1, -2) .. "!"
            assert.has_error(function() incremental.file_contents(ctx, large_path) end,
                large_path .. ": file changed during build")
        end)
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
        local ctx = context({ [fixture_path("/sdk/titan.so")] = "provider bytes" })
        local function binary(name, layouts)
            local modtype = types.Module(name, {}, {})
            modtype.file = fixture_path("/sdk/titan.so")
            return { kind = "binary", type = modtype, filename = fixture_path("/sdk/titan.so"), layouts = layouts }
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
        local ctx = context({ [fixture_path("/src/main.titan")] = "source" })
        ctx.incremental_configuration = configuration()
        local entry = source_entry("main")
        entry.interface_digests = { public = "self-public", source = "self-private" }
        local native = { layouts = "layout", imports = { { name = "direct", source_required = true } },
            bindings = { direct = "direct", owner = "global", main = "direct" }, providers = {} }
        local source = { kind = "flat", main = entry.filename, files = entry.source_files }
        local cert = incremental.make_certificate(ctx, entry, native, {
            source = incremental.source_certificate(ctx, source),
            stem = fixture_path("/out/main"), codegen = certificate().codegen,
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

describe("content-only native input facts", function()
    local scan, read
    before_each(function() scan, read = staticmetadata.scan_bytes, objectmetadata.read end)
    after_each(function() staticmetadata.scan_bytes, objectmetadata.read = scan, read end)
    local function coff()
        return string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0)
    end
    -- `second_name` renames the second section, by default an LTO section.
    local function elf(kind, lto, second_name)
        local names = "\0.shstrtab\0" .. (second_name or ".gnu.lto_.opts") .. "\0"
        local header = "\127ELF\2\1\1" .. string.rep("\0", 9) ..
            string.pack("<I2I2I4I8I8I8I4I2I2I2I2I2I2",
                kind, 62, 1, 0, 0, lto and 64 or 0, 0, 64, 0, 0, 64, lto and 3 or 0, lto and 1 or 0)
        if not lto then return header end
        local section = "<I4I4I8I8I8I8I4I4I8I8"
        return header .. string.rep("\0", 64) ..
            string.pack(section, 1, 3, 0, 0, 256, #names, 0, 0, 1, 0) ..
            string.pack(section, 11, 1, 0, 0, 256 + #names, 1, 0, 0, 1, 0) .. names .. "\0"
    end
    local function archive(member)
        return "!<arch>\n" .. string.format("%-16s%-12d%-6d%-6d%-8s%-10d`\n",
            "helper.o/", 0, 0, 0, "100644", #member) .. member .. (#member % 2 == 1 and "\n" or "")
    end

    it("recognizes import archives and shared images without restoring Titan metadata", function()
        staticmetadata.scan_bytes = function() error("unexpected object metadata scan") end
        objectmetadata.read = function() error("unexpected metadata restoration") end
        local import = string.pack("<I2I2I2I2I4I4I2I2", 0, 0xffff, 0, 0x8664, 0, 0, 0, 0)
        local macho = "\207\250\237\254" .. string.pack("<I4I4I4I4I4I4I4", 0x1000007, 3, 6, 0, 0, 0, 0)
        local pe = "MZ" .. string.rep("\0", 58) .. string.pack("<I4", 64) ..
            "PE\0\0" .. string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0x2000)
        for _, case in ipairs({
            { archive(import), "archive" }, { coff(), "object" },
            { elf(1), "object" }, { elf(3), "shared" }, { macho, "shared" }, { pe, "shared" },
        }) do
            local ctx = context({ [fixture_path("/native")] = case[1] })
            assert.equal(case[2], incremental.native_input_kind(ctx, fixture_path("/native")))
        end
    end)

    it("recognizes bitcode and LTO sections inside ordinary and universal archives", function()
        local member = elf(1, true)
        local universal = "\202\254\186\190" .. string.pack(">I4I4I4I4I4I4",
            1, 0x1000007, 3, 28, #archive(member), 2) .. archive(member)
        for _, bytes in ipairs({ "BC\192\222payload", "\222\192\023\011payload", member,
            archive(member), universal }) do
            local ctx = context({ [fixture_path("/native")] = bytes })
            local kind, err, lto = incremental.native_input_kind(ctx, fixture_path("/native"))
            assert.truthy(kind, err)
            assert.is_true(lto)
        end
    end)

    it("classifies archive members, PE images and COFF section names from content alone", function()
        local function bsd_archive(name, member, declared)
            local size = declared or #name + #member
            return "!<arch>\n" .. string.format("%-16s%-12d%-6d%-6d%-8s%-10d`\n",
                "#1/" .. #name, 0, 0, 0, "100644", size) .. name .. member .. (size % 2 == 1 and "\n" or "")
        end
        -- One section whose long name lives in the string table after the
        -- (empty) symbol table, as LLVM writes `.llvm.lto`.
        local long_name = string.pack("<I4", 14) .. ".llvm.lto\0"
        local section = "/4" .. string.rep("\0", 38)
        local coff_lto = string.pack("<I2I2I4I4I4I2I2", 0x8664, 1, 0, 60, 0, 0, 0) .. section .. long_name
        local coff_text = string.pack("<I2I2I4I4I4I2I2", 0x8664, 1, 0, 60, 0, 0, 0) ..
            ".text" .. string.rep("\0", 35)
        local bigobj_guid = "\199\161\186\209\238\186\169\75\175\32\250\246\106\164\220\184"
        local function bigobj(guid)
            return string.pack("<I2I2I2I2I4", 0, 0xffff, 2, 0x8664, 0) .. guid ..
                string.pack("<I4I4I4I4I4I4I4", 0, 0, 0, 0, 1, 96, 0) .. section .. long_name
        end
        local executable = "MZ" .. string.rep("\0", 58) .. string.pack("<I4", 64) ..
            "PE\0\0" .. string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0x0002)
        local member_name = "long_member_name.o"
        for _, case in ipairs({
            { "ELF sections without LTO", elf(1, true, ".text.startup"), "object", false },
            { "COFF long LTO section name", coff_lto, "object", true },
            { "COFF ordinary section", coff_text, "object", false },
            { "big-object COFF", bigobj(bigobj_guid), "object", true },
            { "BSD long member name", bsd_archive(member_name, elf(1, true)), "archive", true },
            { "big-object COFF with another class", bigobj(string.rep("\0", 16)) },
            { "BSD long name beyond its member", bsd_archive(member_name, "", 4) },
            { "archive member without a header terminator", "!<arch>\n" .. string.rep(" ", 60) },
            { "PE executable image", executable },
        }) do
            local ctx = context({ [fixture_path("/native")] = case[2] })
            local kind, err, lto = incremental.native_input_kind(ctx, fixture_path("/native"))
            if case[3] then
                assert.equal(case[3], kind, case[1] .. ": " .. tostring(err))
                assert.equal(case[4], lto, case[1])
            else
                assert.is_nil(kind, case[1])
                assert.equal("native input is not a recognized object, archive or shared library", err, case[1])
            end
        end
    end)

    it("persists positive and opaque facts without warm payload reads", function()
        local files = { [fixture_path("/native")] = archive(coff()), [fixture_path("/thin")] = "!<thin>\n",
            [fixture_path("/script")] = "INPUT(other.a)\n", [fixture_path("/truncated")] = "\127ELF" }
        local cold = precise_context(files)
        assert(incremental.load_digest_cache(cold, fixture_path("/out")))
        assert.equal("archive", incremental.native_input_kind(cold, fixture_path("/native")))
        for _, path in ipairs({ fixture_path("/thin"), fixture_path("/script"), fixture_path("/truncated") }) do
            local kind, err = incremental.native_input_kind(cold, path)
            assert.is_nil(kind); assert.is_string(err)
        end
        assert(incremental.save_digest_cache(cold))
        local warm = precise_context(files)
        assert(incremental.load_digest_cache(warm, fixture_path("/out")))
        assert.equal("archive", incremental.native_input_kind(warm, fixture_path("/native")))
        for _, path in ipairs({ fixture_path("/thin"), fixture_path("/script"), fixture_path("/truncated") }) do
            assert.is_nil(incremental.native_input_kind(warm, path))
            assert.is_nil(warm.io.reads[path])
        end
        assert.is_nil(warm.io.reads[fixture_path("/native")])
        assert.equal(0, incremental.counters(warm).file_hashes)
    end)

    it("keeps native kind and metadata-free part fingerprints independent", function()
        local files = { [fixture_path("/part.o")] = coff() }
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        assert.equal("object", incremental.native_input_kind(ctx, fixture_path("/part.o")))
        local scans, fingerprint = 0, { format = "coff", word_size = 64, endian = "little", machine = 0x8664 }
        staticmetadata.scan_bytes = function()
            scans = scans + 1
            return { kind = "object", fingerprint = fingerprint }
        end
        objectmetadata.read = function() return { type = {} } end
        local part, err = incremental.part_fingerprint(ctx, fixture_path("/part.o"))
        assert.is_nil(part)
        assert.matches("Titan module metadata", err, 1, true)
        objectmetadata.read = function() return nil end
        assert.same(fingerprint, incremental.part_fingerprint(ctx, fixture_path("/part.o")))
        assert.equal(2, scans)
        assert(incremental.save_digest_cache(ctx))
        local warm = precise_context(files)
        assert(incremental.load_digest_cache(warm, fixture_path("/out")))
        assert.same(fingerprint, incremental.part_fingerprint(warm, fixture_path("/part.o")))
        assert.equal("object", incremental.native_input_kind(warm, fixture_path("/part.o")))
        assert.equal(2, scans)
        assert.is_nil(warm.io.reads[fixture_path("/part.o")])
    end)

    it("recomputes missing kind facts without changing the digest-cache schema", function()
        local files = { [fixture_path("/native")] = coff() }
        local cold = precise_context(files)
        assert(incremental.load_digest_cache(cold, fixture_path("/out")))
        assert.equal("object", incremental.native_input_kind(cold, fixture_path("/native")))
        local digest = incremental.file_digest(cold, fixture_path("/native"))
        local fingerprint = { format = "coff", word_size = 64, endian = "little", machine = 0x8664 }
        cold.incremental.persistent.objects[digest] = { fingerprint = fingerprint }
        assert(incremental.save_digest_cache(cold))
        local warm = precise_context(files)
        assert(incremental.load_digest_cache(warm, fixture_path("/out")))
        assert.equal("object", incremental.native_input_kind(warm, fixture_path("/native")))
        assert.equal(1, warm.io.reads[fixture_path("/native")])
        assert.equal(0, incremental.counters(warm).file_hashes)
        assert.same(fingerprint, incremental.part_fingerprint(warm, fixture_path("/native")))
    end)

    it("discards malformed native facts rather than treating them as format evidence", function()
        for _, invalid in ipairs({ { kind = "script", lto = false }, { kind = "object", lto = "yes" },
            { kind = "object", lto = false, external = fixture_path("/hidden.o") },
            { fingerprint = { format = "coff", word_size = 64, endian = "little", machine = 0x8664,
                section_count = 1 } } }) do
            local files = { [fixture_path("/native")] = coff() }
            local cold = precise_context(files)
            assert(incremental.load_digest_cache(cold, fixture_path("/out")))
            assert.equal("object", incremental.native_input_kind(cold, fixture_path("/native")))
            local digest = incremental.file_digest(cold, fixture_path("/native"))
            cold.incremental.persistent.objects[digest] = invalid
            assert(incremental.save_digest_cache(cold))
            local warm = precise_context(files)
            assert(incremental.load_digest_cache(warm, fixture_path("/out")))
            assert.equal("object", incremental.native_input_kind(warm, fixture_path("/native")))
            assert.equal(1, warm.io.reads[fixture_path("/native")])
            assert.equal(1, incremental.counters(warm).file_hashes)
        end
    end)

    it("reports native read errors and preserves cancellation identity", function()
        local ctx = context({})
        local kind, err = incremental.native_input_kind(ctx, fixture_path("/missing"))
        assert.is_nil(kind); assert.matches(fixture_path("/missing"), err, 1, true)
        ctx = context({ [fixture_path("/native")] = coff() })
        local cancelled = {}
        function ctx.io:read_file() error(cancelled, 0) end
        local ok, raised = pcall(incremental.native_input_kind, ctx, fixture_path("/native"))
        assert.is_false(ok); assert.equal(cancelled, raised)
    end)
end)

describe("persistent precise digest cache", function()
    local path = fixture_path("/src/main.titan")
    -- The cache is a native output path, unlike authored source spellings.
    local cache_path = require("titan-compiler.path").join(fixture_path("/out"), ".titan", "digests")
    local function prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local digest = incremental.file_digest(ctx, path)
        assert(incremental.save_digest_cache(ctx))
        return digest
    end

    it("reuses unchanged content across invocations without reading or hashing", function()
        local files = { [path] = "source" }
        local digest = prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local current, bytes, observed = incremental.file_digest(ctx, path)
        assert.equal(digest, current)
        assert.is_nil(bytes)
        assert.equal("ns", observed.precision)
        assert.is_nil(ctx.io.reads[path])
        local counts = incremental.counters(ctx)
        assert.equal(0, counts.file_reads); assert.equal(0, counts.file_hashes)
        assert.equal(1, counts.observation_reuses)
        assert.equal(1, counts.files[path].observation_reuses)
        assert(incremental.save_digest_cache(ctx))
        assert.is_nil(ctx.io.renames)
    end)

    it("materializes bytes once without rehashing a precise cache hit", function()
        local files = { [path] = "source" }; prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        assert.equal("source", incremental.file_contents(ctx, path, 6))
        assert.equal("source", incremental.file_contents(ctx, path, 6))
        assert.equal(1, ctx.io.reads[path])
        assert.equal(0, incremental.counters(ctx).file_hashes)
        assert.has_error(function() incremental.file_contents(ctx, path, 5) end,
            path .. ": file exceeds read limit")
    end)

    for _, change in ipairs({
        { "dev", "2" }, { "ino", "replacement" }, { "size", 7 }, { "mode", 0x81a4 },
        { "mtime_ns", 1000000001 }, { "ctime_ns", 1000000001 }, { "precision", "coarse" },
    }) do
        it("rehashes after a different " .. change[1] .. " observation", function()
            local files = { [path] = "source" }; prime(files)
            local ctx = precise_context(files)
            ctx.io.observation_changes[path] = { [change[1]] = change[2] }
            if change[1] == "size" then files[path] = "sources" end
            assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
            assert.equal(sha256.hex(files[path]), (incremental.file_digest(ctx, path)))
            assert.equal(1, ctx.io.reads[path])
            assert.equal(0, incremental.counters(ctx).observation_reuses)
            assert.equal(1, incremental.counters(ctx).file_hashes)
        end)
    end

    it("requires every precise field and a readable regular file", function()
        local files = { [path] = "source" }; prime(files)
        for _, omitted in ipairs({ { "ctime_ns" }, { "dev", "ino" } }) do
            local ctx = precise_context(files)
            local stat = ctx.io.stat
            function ctx.io:stat(name)
                local value, err = stat(self, name)
                if name == path and value then
                    for _, field in ipairs(omitted) do value[field] = nil end
                end
                return value, err
            end
            assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
            assert.equal(sha256.hex("source"), (incremental.file_digest(ctx, path)))
            assert.equal(1, incremental.counters(ctx).file_hashes, omitted[1])
            assert.equal(0, incremental.counters(ctx).observation_reuses, omitted[1])
        end
        local unreadable = precise_context(files)
        assert(incremental.load_digest_cache(unreadable, fixture_path("/out")))
        function unreadable.io:readable() return false end
        function unreadable.io:read_file(name)
            if name == path then return nil, "permission denied" end
            return files[name]
        end
        assert.has_error(function() incremental.file_digest(unreadable, path) end, "permission denied")
        assert.equal(0, incremental.counters(unreadable).observation_reuses)
        local changed_kind = precise_context(files)
        changed_kind.io.observation_changes[path] = { kind = "directory" }
        assert(incremental.load_digest_cache(changed_kind, fixture_path("/out")))
        assert.has_error(function() incremental.file_digest(changed_kind, path) end)
        assert.equal(0, incremental.counters(changed_kind).observation_reuses)
    end)

    it("falls back after an observation error and propagates cancellation", function()
        local files = { [path] = "source" }; prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local stat, failed = ctx.io.stat, false
        function ctx.io:stat(name)
            if name == path and not failed then failed = true; return nil, "temporary stat failure" end
            return stat(self, name)
        end
        incremental.file_digest(ctx, path)
        assert.equal(1, incremental.counters(ctx).file_hashes)
        local cancelled = {}
        local other = precise_context(files)
        assert(incremental.load_digest_cache(other, fixture_path("/out")))
        function other.io:stat() error(cancelled, 0) end
        local ok, err = pcall(incremental.file_digest, other, path)
        assert.is_false(ok); assert.equal(cancelled, err)
    end)

    it("falls back after a raised observation failure", function()
        local files = { [path] = "source" }; prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local stat, failed = ctx.io.stat, false
        function ctx.io:stat(name)
            if name == path and not failed then failed = true; error("stat interrupted", 0) end
            return stat(self, name)
        end
        assert.equal(sha256.hex("source"), (incremental.file_digest(ctx, path)))
        assert.equal(1, incremental.counters(ctx).file_hashes)
        assert.equal(0, incremental.counters(ctx).observation_reuses)
    end)

    it("verifies caller-supplied bytes against a digest-only cache hit", function()
        local files = { [path] = "source" }
        local digest = prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local _, bytes = incremental.file_digest(ctx, path)
        assert.is_nil(bytes)
        -- Bytes the caller read itself are checked once and then retained.
        assert.equal(digest, (incremental.file_digest(ctx, path, "source")))
        assert.equal("source", select(2, incremental.file_digest(ctx, path)))
        assert.equal(1, incremental.counters(ctx).file_hashes)
        assert.equal(6, incremental.counters(ctx).file_bytes)
        assert.is_nil(ctx.io.reads[path])
        local other = precise_context(files)
        assert(incremental.load_digest_cache(other, fixture_path("/out")))
        incremental.file_digest(other, path)
        assert.has_error(function() incremental.file_digest(other, path, "edited") end,
            path .. ": file changed during build")
    end)

    it("binds one invocation's persistent cache to one output tree", function()
        local ctx = precise_context({ [path] = "source" })
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        assert.is_true(incremental.load_digest_cache(ctx, fixture_path("/out")))
        local ok, err = incremental.load_digest_cache(ctx, fixture_path("/elsewhere"))
        assert.is_nil(ok)
        assert.equal("digest cache already belongs to another output tree", err)
        assert.equal(cache_path, ctx.incremental.persistent.path)
    end)

    it("treats an unreadable cache as absent and propagates cancellation while reading it", function()
        local files = { [path] = "source" }; prime(files)
        local ctx = precise_context(files)
        local lstat = ctx.io.lstat
        function ctx.io:lstat(name)
            if name == cache_path then error("cache read interrupted", 0) end
            return lstat(self, name)
        end
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        incremental.file_digest(ctx, path)
        assert.equal(1, incremental.counters(ctx).file_hashes)
        local cancelled = {}
        local other = precise_context(files)
        function other.io:lstat() error(cancelled, 0) end
        local loaded, err = pcall(incremental.load_digest_cache, other, fixture_path("/out"))
        assert.is_false(loaded)
        assert.equal(cancelled, err)
    end)

    it("removes the staged SDK digest manifest when it cannot be published", function()
        local files = { [path] = "source" }
        local ctx = precise_context(files)
        local manifest = fixture_path("/sdk/sdk-digests")
        function ctx.io:rename() return nil, "manifest is busy" end
        local ok, err = pcall(incremental.write_sdk_digests, ctx, manifest, { path })
        assert.is_false(ok)
        assert.equal("manifest is busy", err)
        assert.is_nil(files[manifest])
        for name in pairs(files) do assert.is_nil(name:find(".tmp.", 1, true), name) end
    end)

    it("does not reuse an observation through a different path spelling", function()
        local files = { [path] = "source" }; prime(files)
        local ctx = precise_context(files)
        ctx.io.aliases[fixture_path("/alias.titan")] = path
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        incremental.file_digest(ctx, fixture_path("/alias.titan"))
        assert.equal(1, incremental.counters(ctx).file_hashes)
        assert.equal(0, incremental.counters(ctx).observation_reuses)
    end)

    it("ignores malformed old and incomplete cache envelopes", function()
        local codec = require "titan-compiler.graphcodec"
        for _, payload in ipairs({ "malformed",
            assert(codec.encode({ schema = "old", files = {}, objects = {} })),
            assert(codec.encode({ schema = version.DIGEST_CACHE_SCHEMA,
                digest = version.CERTIFICATE_DIGEST, canonicalization = version.CERTIFICATE_CANONICALIZATION,
                abi = version.TITAN_ABI_VERSION, files = { [path] = { digest = sha256.hex("wrong") } },
                objects = {} })),
        }) do
            local files = { [path] = "source", [cache_path] = payload }
            local ctx = precise_context(files)
            assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
            assert.equal(cache_path, ctx.incremental.persistent.path)
            assert.equal(1, ctx.io.reads[cache_path])
            incremental.file_digest(ctx, path)
            assert.equal(1, incremental.counters(ctx).file_hashes)
            assert(incremental.save_digest_cache(ctx))
            assert.equal(1, ctx.io.renames)
            assert.equal(version.DIGEST_CACHE_SCHEMA, assert(codec.decode(files[cache_path])).schema)
            local warm = precise_context(files)
            assert(incremental.load_digest_cache(warm, fixture_path("/out")))
            assert.equal(sha256.hex("source"), (incremental.file_digest(warm, path)))
            assert.is_nil(warm.io.reads[path])
            assert.equal(0, incremental.counters(warm).file_hashes)
        end
    end)

    it("retains the previous complete cache if publication fails", function()
        local files = { [path] = "source" }; prime(files)
        local previous = files[cache_path]
        assert.is_string(previous)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        ctx.io.clock, files[path] = 2, "edited"
        incremental.file_digest(ctx, path)
        function ctx.io:rename() return nil, "rename denied" end
        local ok, err = incremental.save_digest_cache(ctx)
        assert.is_nil(ok); assert.equal("rename denied", err)
        assert.equal(previous, files[cache_path])
        for name in pairs(files) do assert.is_nil(name:find(".tmp.", 1, true)) end
    end)

    it("keeps source-adjacent and worker contexts out of persistent storage", function()
        local files = { [path] = "source" }
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, nil))
        incremental.file_digest(ctx, path)
        assert(incremental.save_digest_cache(ctx))
        assert.is_nil(files[cache_path])
        local worker = precise_context(files)
        incremental.file_digest(worker, path)
        assert(incremental.save_digest_cache(worker))
        assert.is_nil(files[cache_path])
    end)

    it("re-observes publication inputs and rehashes only changed ones", function()
        local files = { [path] = "source" }
        local digest = prime(files)
        local ctx = precise_context(files)
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        assert.equal(digest, (incremental.file_digest(ctx, path)))
        local fresh = incremental.fresh_context(ctx)
        assert.equal(digest, (incremental.file_digest(fresh, path)))
        assert.equal(0, incremental.counters(fresh).file_hashes)
        assert.equal(1, incremental.counters(fresh).observation_reuses)
        assert.is_nil(ctx.io.reads[path])
        -- A touch with equal content is reread and still has the same identity.
        ctx.io.observation_changes[path] = { ctime_ns = 3000000000 }
        local touched = incremental.fresh_context(ctx)
        assert.equal(digest, (incremental.file_digest(touched, path)))
        assert.equal(1, incremental.counters(touched).file_hashes)
        assert.equal(1, ctx.io.reads[path])
        -- Changed content gets its new digest and primes the shared cache.
        files[path], ctx.io.observation_changes[path] = "edited", { ctime_ns = 4000000000 }
        local edited = incremental.fresh_context(ctx)
        assert.equal(sha256.hex("edited"), (incremental.file_digest(edited, path)))
        assert.equal(sha256.hex("edited"), ctx.incremental.persistent.files[path].digest)
        assert.equal(0, incremental.counters(ctx).file_hashes)
        assert(incremental.save_digest_cache(edited))
        assert.is_nil(ctx.io.renames)
    end)
end)

describe("incremental configuration", function()
    local function configured()
        local ctx, files = native_context({ [fixture_path("/compiler/titan-compiler/driver.lua")] = "driver",
            [fixture_path("/compiler/titan-compiler/checker/entry.lua")] = "checker",
            [fixture_path("/compiler/titan-compiler/coder/generate.lua")] = "coder",
            [fixture_path("/compiler/c-parser/cpp.lua")] = "parser", [fixture_path("/real/titanc")] = "real frontend",
            [fixture_path("/compiler/c-parser/cdefines.lua")] = "macro registrar",
            [fixture_path("/bin/titanc")] = "wrapper", [fixture_path("/sdk/common.h")] = "header", [native_tool("cc")] = "tool" })
        ctx.incremental_options = { compiler_root = fixture_path("/compiler"), frontend = fixture_path("/real/titanc"),
            preamble_path = fixture_path("/out/.titan/preamble.c"), compile_prefix = { native_tool("cc"), "-O2" },
            toolchain_descriptor = { compiler_argv = { native_tool("cc") },
                preprocessor_identity = "macros", banner = "clang version 22.1.8 (fixture)", stage_tools = {} },
            build_profile = "validation", emit_line_directives = true, titan_root = fixture_path("/sdk") }
        -- Inventory joins use the host-native path module, independently of
        -- controlled POSIX executable-name models below. Admit only alternate
        -- separators for this fixture's compiler files and parent directories.
        local paths = require "titan-compiler.path"
        local root, inventory_paths = ctx.incremental_options.compiler_root, {}
        for filename in pairs(files) do
            if filename:sub(1, #root + 1) == root .. "/" then
                local entry = filename
                while entry and #entry > #root do
                    local native = paths.join(root, entry:sub(#root + 2))
                    if native ~= entry then
                        inventory_paths[native] = entry
                        ctx.io.aliases[native] = entry
                    end
                    entry = entry:match("^(.*)/[^/]+$")
                end
            end
        end
        local list = ctx.io.list
        function ctx.io:list(directory)
            return list(self, inventory_paths[directory] or directory)
        end
        return ctx, files
    end

    it("computes one invocation certificate and inventories the real frontend not its wrapper", function()
        local ctx = configured()
        local cert = incremental.configuration(ctx)
        assert.equal(cert, incremental.configuration(ctx))
        assert.equal(1, #ctx.io.commands)
        assert.equal(1, ctx.io.reads[fixture_path("/real/titanc")])
        assert.is_nil(ctx.io.reads[fixture_path("/bin/titanc")])
        assert.is_nil(ctx.io.reads[native_tool("cc")])
        for _, file in pairs(incremental.counters(ctx).files) do assert.equal(1, file.hashes) end
        assert.equal(cpreamble.certification_includes, ctx.io.writes[fixture_path("/out/.titan/preamble.c")] and
            select(2, incremental.file_digest(ctx, fixture_path("/out/.titan/preamble.c"))))
    end)

    it("verifies the worker compiler component without native probes", function()
        local ctx = configured()
        local compiler = assert(incremental.compiler_component(ctx))
        assert.same({}, ctx.io.commands)
        assert.equal(compiler, incremental.configuration(ctx).compiler)
        assert.equal(1, #ctx.io.commands)
    end)

    it("invalidates compiler certificates after macro inference changes",
    function()
        local first = configured()
        local second, files = configured()
        files[fixture_path("/compiler/c-parser/cdefines.lua")] =
            "corrected macro registrar"
        local before, after = incremental.configuration(first),
            incremental.configuration(second)
        assert.not_equal(before.compiler, after.compiler)
        assert.not_equal(before.digest, after.digest)
        assert.equal(before.options, after.options)
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

    local function with_posix_search(path, body)
        local windows, getenv = platform.windows, platform.getenv
        platform.windows = false
        platform.getenv = function(name)
            assert.equal("PATH", name)
            return path
        end
        local results = table.pack(pcall(body))
        platform.windows, platform.getenv = windows, getenv
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end

    local function posix_search_context(command, changed)
        local winner, shadow, later =
            "/winner/" .. command, "/coordinator/" .. command, "/later/" .. command
        local ctx = context({ [winner] = "selected", [shadow] = "cwd shadow", [later] = "later shadow" })
        function ctx.io:cwd() return "/coordinator" end
        ctx.io.aliases["./" .. command] = shadow
        ctx.io.aliases["/coordinator/./" .. command] = shadow
        local stat = ctx.io.stat
        function ctx.io:stat(path)
            local value, err = stat(self, path)
            if value and (self.aliases[path] or path) == changed then
                value.changed_seconds = value.changed_seconds + 1
            end
            return value, err
        end
        return ctx, winner, shadow, later
    end

    local function posix_search_descriptor(command)
        return { compiler_argv = { command }, stage_tools = {},
            preprocessor_identity = "#define POSIX_SEARCH_FIXTURE 1\n",
            banner = "clang version 22.1.8 (fixture)" }
    end

    for _, case in ipairs({
        { name = "c:cc", kind = "colon" },
        { name = "c\\cc", kind = "backslash" },
    }) do
        it("searches PATH for a slash-free POSIX name containing a " .. case.kind, function()
            with_posix_search("/ambient", function()
                local function identity(changed)
                    local ctx, winner, shadow, later = posix_search_context(case.name, changed)
                    ctx.executable_path = "/winner:/later"
                    local digest, details, status =
                        incremental.toolchain_identity(ctx, posix_search_descriptor(case.name))
                    assert.is_string(digest)
                    assert.is_nil(status)
                    assert.equal(winner, details.tools[1].path)
                    local physical, selected = incremental.physical_executable(ctx, case.name)
                    assert.same(details.tools[1], physical)
                    assert.equal(winner, selected)
                    assert.equal(0, incremental.counters(ctx).file_hashes)
                    assert.same({}, ctx.io.reads)
                    assert.same({}, ctx.io.commands)
                    return digest, details, winner, shadow, later
                end
                local first, details, winner, shadow, later = identity()
                local replaced, replaced_details = identity(winner)
                assert.is_not.equal(first, replaced)
                assert.equal(details.preprocessor, replaced_details.preprocessor)
                assert.equal(details.banner, replaced_details.banner)
                assert.equal(details.tools[1].path, replaced_details.tools[1].path)
                assert.equal(details.tools[1].changed_seconds + 1,
                    replaced_details.tools[1].changed_seconds)
                assert.equal(first, (identity(shadow)))
                assert.equal(first, (identity(later)))
            end)
        end)
    end

    for _, case in ipairs({
        { name = "ambient", environment = "" },
        { name = "explicit", override = "" },
    }) do
        it("retains CWD search for an " .. case.name .. " empty POSIX PATH", function()
            with_posix_search(case.environment, function()
                local function identity(changed)
                    local ctx, winner, shadow = posix_search_context("cc", changed)
                    ctx.executable_path = case.override
                    local digest, details, status =
                        incremental.toolchain_identity(ctx, posix_search_descriptor("cc"))
                    assert.is_string(digest)
                    assert.is_nil(status)
                    assert.equal(shadow, details.tools[1].path)
                    local physical, selected = incremental.physical_executable(ctx, "cc")
                    assert.same(details.tools[1], physical)
                    assert.equal("/coordinator/./cc", selected)
                    assert.equal(0, incremental.counters(ctx).file_hashes)
                    assert.same({}, ctx.io.reads)
                    assert.same({}, ctx.io.commands)
                    return digest, shadow, winner
                end
                local first, shadow, winner = identity()
                assert.is_not.equal(first, (identity(shadow)))
                assert.equal(first, (identity(winner)))
            end)
        end)
    end

    it("leaves an unset POSIX executable default uncertified without guessing CWD", function()
        local expected_reason, expected_status
        with_posix_search(nil, function()
            local ctx = posix_search_context("cc")
            function ctx.io:stat() error("unset PATH must not guess a candidate") end
            local physical, reason, status = incremental.physical_executable(ctx, "cc")
            assert.is_nil(physical)
            assert.matches("POSIX default executable search path", reason, 1, true)
            assert.equal("uncertified", status)
            local digest, toolchain_reason, toolchain_status =
                incremental.toolchain_identity(ctx, posix_search_descriptor("cc"))
            assert.is_nil(digest)
            assert.equal(reason, toolchain_reason)
            assert.equal(status, toolchain_status)
            assert.same({}, ctx.incremental.toolchains)
            assert.same({}, ctx.io.reads)
            assert.same({}, ctx.io.commands)
            expected_reason, expected_status = reason, status
        end)
        -- Keep real compiler inventory under host semantics; only the real
        -- toolchain lookup receives the controlled POSIX PATH environment.
        local configured_ctx = configured()
        configured_ctx.incremental_options.toolchain_descriptor.compiler_argv = { "cc" }
        local toolchain_identity = incremental.toolchain_identity
        incremental.toolchain_identity = function(ctx, descriptor)
            return with_posix_search(nil, function()
                return toolchain_identity(ctx, descriptor)
            end)
        end
        local called, config, config_reason, config_status =
            pcall(incremental.configuration, configured_ctx)
        incremental.toolchain_identity = toolchain_identity
        assert.is_true(called, tostring(config))
        assert.is_nil(config)
        assert.equal(expected_reason, config_reason)
        assert.equal(expected_status, config_status)
        assert.is_nil(configured_ctx.incremental_configuration)
        assert.same({}, configured_ctx.io.commands)
        assert.equal(6, incremental.counters(configured_ctx).file_reads)
        assert.equal(6, incremental.counters(configured_ctx).file_hashes)
    end)

    it("admits explicit POSIX paths without consulting an unset PATH", function()
        with_posix_search(nil, function()
            local ctx, _, shadow = posix_search_context("cc")
            platform.getenv = function() error("explicit paths must not query PATH") end
            for _, command in ipairs({ shadow, "./cc" }) do
                local physical, selected = incremental.physical_executable(ctx, command)
                assert.equal(shadow, physical.path)
                assert.equal(command == shadow and shadow or "/coordinator/./cc", selected)
            end
            assert.same({}, ctx.io.reads)
            assert.same({}, ctx.io.commands)
        end)
    end)

    it("preserves POSIX PATH lookup errors and cancellation for literal command names", function()
        with_posix_search("/winner", function()
            local cancelled = {}
            for _, command in ipairs({ "c:cc", "c\\cc" }) do
                local ctx, winner = posix_search_context(command)
                local stat = ctx.io.stat
                local failure = "injected PATH lookup failure"
                function ctx.io:stat(path)
                    if path == winner then return nil, failure end
                    return stat(self, path)
                end
                local called, err = pcall(incremental.physical_executable, ctx, command)
                assert.is_false(called)
                assert.matches(failure, err, 1, true)
                failure = cancelled
                called, err = pcall(incremental.physical_executable, ctx, command)
                assert.is_false(called)
                assert.equal(cancelled, err)
                ctx.executable_path = nil
                platform.getenv = function() error(cancelled, 0) end
                called, err = pcall(incremental.physical_executable, ctx, command)
                assert.is_false(called)
                assert.equal(cancelled, err)
                platform.getenv = function() return "/winner" end
            end
        end)
    end)

    it("retains selected executable spelling separately from canonical identity", function()
        local platform = require "titan-compiler.platform"
        if platform.windows then pending("POSIX relative PATH selection"); return end
        local ctx = context({ ["/target/llvm-multicall"] = "selected",
            ["/shadow/dsymutil"] = "shadow" })
        local candidate = platform.join(".", "dsymutil")
        ctx.io.aliases[candidate] = "/target/llvm-multicall"
        function ctx.io:cwd() return "/coordinator" end
        ctx.executable_path = ".:/shadow"
        local observed, stat = {}, ctx.io.stat
        function ctx.io:stat(path)
            observed[#observed + 1] = path
            return stat(self, path)
        end
        local identity, selected = incremental.physical_executable(ctx, "dsymutil")
        assert.same({ candidate }, observed)
        assert.equal("/target/llvm-multicall", identity.path)
        assert.equal("/coordinator/./dsymutil", selected)
        local direct = incremental.physical_executable(ctx, "/target/llvm-multicall")
        assert.same(direct, identity)
        assert.equal(0, #ctx.io.commands)
        assert.is_nil(ctx.io.reads["/target/llvm-multicall"])
    end)

    it("preserves symlink-directory traversal in POSIX PATH candidates", function()
        local platform = require "titan-compiler.platform"
        if platform.windows then pending("POSIX symlink-directory PATH traversal"); return end
        local ctx = context({ ["/a/bin/dsymutil"] = "lexically normalized",
            ["/b/bin/dsymutil"] = "physically selected" })
        local candidate = "/a/link/../bin/dsymutil"
        ctx.io.aliases[candidate] = "/b/bin/dsymutil"
        ctx.executable_path = "/a/link/../bin:/a/bin"
        local identity, selected = incremental.physical_executable(ctx, "dsymutil")
        assert.equal("/b/bin/dsymutil", identity.path)
        assert.equal(candidate, selected)
        assert.equal(0, #ctx.io.commands)
        assert.is_nil(ctx.io.reads["/a/bin/dsymutil"])
        assert.is_nil(ctx.io.reads["/b/bin/dsymutil"])
    end)

    it("selects an execute-only tool without reading its contents", function()
        local platform = require "titan-compiler.platform"
        if platform.windows then pending("POSIX effective execution access"); return end
        local ctx = context({ ["/first/tool"] = "execute only", ["/later/tool"] = "later" })
        ctx.executable_path = "/first:/later"
        local stat = ctx.io.stat
        function ctx.io:stat(path)
            local value = stat(self, path)
            value.mode = 0x8049 -- 0111, with no read permission.
            return value
        end
        function ctx.io:readable() error("tool identity must not test readability") end
        function ctx.io:read_file() error("tool identity must not read contents") end
        local checked = {}
        function ctx.io:executable(path) checked[#checked + 1] = path; return true end
        local identity, selected = incremental.physical_executable(ctx, "tool")
        assert.equal("/first/tool", identity.path)
        assert.equal("/first/tool", selected)
        assert.same({ "/first/tool" }, checked)
        assert.equal(0, #ctx.io.commands)
    end)

    for _, mode in ipairs({ 0x81ac, 0x8101 }) do -- Same-owner 0654 and 0401.
        it("skips a definitely ineligible tool despite another class's execute bit " .. mode, function()
            local platform = require "titan-compiler.platform"
            if platform.windows then pending("POSIX effective execution access"); return end
            local ctx = context({ ["/first/tool"] = "not executable", ["/later/tool"] = "selected" })
            ctx.executable_path = "/first:/later"
            local stat = ctx.io.stat
            function ctx.io:stat(path)
                local value = stat(self, path)
                if path == "/first/tool" then value.mode = mode end
                return value
            end
            function ctx.io:readable() error("tool admission must not test readability") end
            local checked = {}
            function ctx.io:executable(path)
                checked[#checked + 1] = path
                return path == "/later/tool"
            end
            assert.equal("/later/tool", incremental.physical_executable(ctx, "tool").path)
            assert.same({ "/first/tool", "/later/tool" }, checked)
            assert.equal(0, #ctx.io.commands)
        end)
    end

    for _, result in ipairs({ "missing", "error", "unknown", "invalid", "false-error" }) do
        it("fails closed for " .. result .. " execution eligibility", function()
            local platform = require "titan-compiler.platform"
            if platform.windows then pending("POSIX effective execution access"); return end
            local ctx = context({ ["/first/tool"] = "first", ["/later/tool"] = "later" })
            ctx.executable_path = "/first:/later"
            local checked = {}
            ctx.io.executable = result ~= "missing" and function(_, path)
                checked[#checked + 1] = path
                if result == "error" then return nil, "injected access failure" end
                if result == "false-error" then return false, "injected access failure" end
                if result == "invalid" then return "not a boolean" end
            end or nil
            function ctx.io:readable() error("eligibility must not fall back to readability") end
            local ok, err = pcall(incremental.physical_executable, ctx, "tool")
            assert.is_false(ok)
            assert.is_string(err)
            if result == "error" or result == "false-error" then
                assert.matches("injected access failure", err, 1, true)
            else
                assert.matches("cannot determine native tool execution eligibility", err, 1, true)
            end
            assert.same(result == "missing" and {} or { "/first/tool" }, checked)
            assert.equal(0, #ctx.io.commands)
        end)
    end

    it("propagates execution eligibility cancellation unchanged", function()
        local platform = require "titan-compiler.platform"
        if platform.windows then pending("POSIX effective execution access"); return end
        local ctx = context({ ["/first/tool"] = "first", ["/later/tool"] = "later" })
        ctx.executable_path = "/first:/later"
        local cancelled = {}
        function ctx.io:executable() return nil, cancelled end
        local ok, err = pcall(incremental.physical_executable, ctx, "tool")
        assert.is_false(ok)
        assert.equal(cancelled, err)
        function ctx.io:executable() error(cancelled, 0) end
        ok, err = pcall(incremental.physical_executable, ctx, "tool")
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)

    it("does not skip a Windows tool because it is unreadable", function()
        local platform = require "titan-compiler.platform"
        local original = platform.windows
        local ctx = context({ ["C:/first/tool.exe"] = "selected", ["C:/later/tool.exe"] = "later" })
        ctx.executable_path = "C:/first;C:/later"
        function ctx.io:executable_search_cwd() return false end
        function ctx.io:readable() error("Windows selection must not test readability") end
        function ctx.io:executable() error("Windows selection must not query POSIX eligibility") end
        platform.windows = true
        local ok, identity, selected = pcall(incremental.physical_executable, ctx, "tool.exe")
        platform.windows = original
        assert.is_true(ok, identity)
        assert.equal("C:/first/tool.exe", identity.path)
        assert.equal("C:/first/tool.exe", selected)
        assert.equal(0, #ctx.io.commands)
    end)

    it("probes one flagless toolchain description independently of effective options", function()
        local ctx = native_context({ [native_tool("cc")] = "driver" })
        local null = require("titan-compiler.platform").windows and "NUL" or "/dev/null"
        function ctx.io:run(argv)
            self.commands[#self.commands + 1] = argv
            if argv[2] == "-dM" then
                assert.same({ native_tool("cc"), "-dM", "-E", "-x", "c", null }, argv)
                return { started = true, ok = true, output = "#define __COMPILER_VERSION__ 1\n" }
            end
            assert.same({ native_tool("cc"), "-E", "-v", "-x", "c", null, "-o", null }, argv)
            return { started = true, ok = true, output = "clang version 22.1.8 fixed vendor banner" }
        end
        local descriptor = { compiler_argv = { native_tool("cc") },
            compile_flags = { "-O1", "-DEFFECTIVE_OPTION=1" }, include_dirs = { fixture_path("/first-sdk") },
            profile_identity = "first-effective-profile", stage_tools = {} }
        local first = incremental.toolchain_identity(ctx, descriptor)
        descriptor.cppflags = { "-DCHANGED_CPP_OPTION=1" }
        descriptor.compile_flags = { "-O3", "-DEFFECTIVE_OPTION=2" }
        descriptor.include_dirs = { fixture_path("/second-sdk") }
        descriptor.profile_identity = "second-effective-profile"
        assert.equal(first, incremental.toolchain_identity(ctx, descriptor))
        assert.equal(2, #ctx.io.commands)
        assert.equal(0, incremental.counters(ctx).file_hashes)
    end)

    local function described_family_identity(banner, flags, changed_stage)
        local ctx = native_context({
            [native_tool("cc")] = "driver",
            [native_tool("cc1")] = "compiler stage",
            [native_tool("as")] = "assembler",
        })
        local stat = ctx.io.stat
        function ctx.io:stat(path)
            local value, err = stat(self, path)
            if value and changed_stage and path == native_tool(changed_stage) then
                value.changed_seconds = value.changed_seconds + 1
            end
            return value, err
        end
        function ctx.io:run(argv)
            self.commands[#self.commands + 1] = argv
            local stage = argv[#argv]:match("^-print%-prog%-name=(.*)$")
            assert.is_true(stage == "cc1" or stage == "as")
            local expected = { native_tool("cc") }
            for _, flag in ipairs(flags) do expected[#expected + 1] = flag end
            expected[#expected + 1] = "-print-prog-name=" .. stage
            assert.same(expected, argv)
            return { started = true, ok = true, output = native_tool(stage) .. "\n" }
        end
        local digest, details, status = incremental.toolchain_identity(ctx, {
            compiler_argv = { native_tool("cc") },
            preprocessor_identity = "#define COMPILER_FAMILY_FIXTURE 1\n",
            banner = banner, compile_flags = flags,
        })
        assert.equal(0, incremental.counters(ctx).file_hashes)
        assert.same({}, ctx.io.reads)
        return digest, details, status, ctx
    end

    local gcc_in_clang_path = table.concat({
        "Using built-in specs.",
        "COLLECT_GCC=/opt/clang-tools/bin/gcc",
        "COLLECT_LTO_WRAPPER=/opt/clang-tools/libexec/gcc/lto-wrapper",
        "gcc version 15.2.0 (fixture)",
    }, "\n")

    it("inventories GCC stages independently of incidental clang installation paths", function()
        local digest, details, status, ctx =
            described_family_identity(gcc_in_clang_path, {})
        assert.same({
            { native_tool("cc"), "-print-prog-name=cc1" },
            { native_tool("cc"), "-print-prog-name=as" },
        }, ctx.io.commands)
        if platform.windows then
            assert.is_nil(digest)
            assert.is_string(details)
            assert.equal("uncertified", status)
        else
            assert.is_string(digest)
            assert.is_nil(status)
            assert.is_nil(details.stage_policy)
            assert.equal(3, #details.tools)
            assert.equal(native_tool("cc"), details.tools[1].path)
            assert.equal(native_tool("cc1"), details.tools[2].path)
            assert.equal(native_tool("as"), details.tools[3].path)
        end
    end)

    for _, stage in ipairs({ "cc1", "as" }) do
        it("keeps selected GCC " .. stage .. " replacement observable with incidental clang paths", function()
            local before, before_details, before_status, before_ctx =
                described_family_identity(gcc_in_clang_path, {})
            local after, after_details, after_status, after_ctx =
                described_family_identity(gcc_in_clang_path, {}, stage)
            assert.same(before_ctx.io.commands, after_ctx.io.commands)
            assert.equal(2, #after_ctx.io.commands)
            if platform.windows then
                assert.is_nil(before)
                assert.is_nil(after)
                assert.is_string(before_details)
                assert.is_string(after_details)
                assert.equal("uncertified", before_status)
                assert.equal("uncertified", after_status)
            else
                assert.is_nil(before_status)
                assert.is_nil(after_status)
                assert.is_not.equal(before, after)
                assert.equal(before_details.banner, after_details.banner)
                assert.equal(before_details.preprocessor, after_details.preprocessor)
                assert.equal(3, #before_details.tools)
                assert.equal(3, #after_details.tools)
                for index, identity in ipairs(before_details.tools) do
                    local changed = after_details.tools[index]
                    assert.equal(identity.path, changed.path)
                    if identity.path == native_tool(stage) then
                        assert.equal(identity.changed_seconds + 1, changed.changed_seconds)
                    else
                        assert.same(identity, changed)
                    end
                end
            end
        end)
    end

    it("retains Clang integrated and external assembler selection from its version line", function()
        for _, banner in ipairs({
            "clang version 22.1.8 (fixture)",
            "Apple clang version 21.0.0 (clang-2100.3.34.2)",
        }) do
            for _, mode in ipairs({
                { flags = {}, external = false },
                { flags = { "-fintegrated-as" }, external = false },
                { flags = { "-fno-integrated-as" }, external = true },
                { flags = { "-fno-integrated-as", "-fintegrated-as" }, external = false },
                { flags = { "-fintegrated-as", "-fno-integrated-as" }, external = true },
            }) do
                local digest, details, status, ctx =
                    described_family_identity(banner, mode.flags)
                assert.is_string(digest)
                assert.is_nil(status)
                assert.equal("llvm", details.stage_policy)
                assert.equal(mode.external and 2 or 1, #details.tools)
                assert.equal(mode.external and 1 or 0, #ctx.io.commands)
                assert.equal(native_tool("cc"), details.tools[1].path)
                if mode.external then
                    assert.equal(native_tool("as"), details.tools[2].path)
                    assert.equal("-print-prog-name=as", ctx.io.commands[1][#mode.flags + 2])
                end
                local replaced_as, replaced_details =
                    described_family_identity(banner, mode.flags, "as")
                assert.same(details.tools[1], replaced_details.tools[1])
                if mode.external then
                    assert.is_not.equal(digest, replaced_as)
                    assert.equal(details.tools[2].changed_seconds + 1,
                        replaced_details.tools[2].changed_seconds)
                else
                    assert.equal(digest, replaced_as)
                end
                local replaced_cc1 = described_family_identity(banner, mode.flags, "cc1")
                assert.equal(digest, replaced_cc1)
            end
        end
    end)

    it("separates stable tool metadata from verbose compiler action commands", function()
        local header = table.concat({
            "Apple clang version 21.0.0 (clang-2100.3.34.2)",
            "Target: arm64-apple-darwin27.0.0",
            "Thread model: posix",
            "InstalledDir: /Library/Developer/CommandLineTools/usr/bin",
            " (in-process)",
        }, "\n")
        local footer = table.concat({
            "clang -cc1 version 21.0.0 based upon LLVM 21.0.0",
            '#include "..." search starts here:',
            "#include <...> search starts here:",
            " /sdk/include",
            "End of search list.",
        }, "\n") .. "\n"
        local function identity(cwd, change, clock)
            local ctx = native_context({ [native_tool("cc")] = "driver", [native_tool("as")] = "assembler" })
            ctx.io.clock = clock or 1
            local action = ' "' .. native_tool("compiler with spaces") .. '" "-cc1" "-triple" "arm64-apple-darwin" ' ..
                '"-E" "-fdebug-compilation-dir=' .. cwd .. '" "-fcoverage-compilation-dir=' .. cwd .. '"'
            local banner = header .. "\n" .. action .. "\n" .. footer
            local descriptor = { compiler_argv = { native_tool("cc") },
                preprocessor_identity = "#define __COMPILER_VERSION__ 1\n",
                banner = banner, stage_tools = { native_tool("as") } }
            if change then change(descriptor, ctx) end
            local digest, details = incremental.toolchain_identity(ctx, descriptor)
            assert.equal(0, #ctx.io.commands)
            assert.equal(0, incremental.counters(ctx).file_hashes)
            return digest, details
        end
        local first, details = identity("/repository")
        assert.truthy(details.banner:find(header, 1, true))
        assert.truthy(details.banner:find(footer, 1, true))
        assert.truthy(details.banner:find("'-cc1' '-triple' 'arm64-apple-darwin'", 1, true))
        assert.is_nil(details.banner:find("/repository", 1, true))
        assert.equal(first, (identity("/workspace with spaces")))
        for _, replacement in ipairs({
            { "clang%-2100%.3%.34%.2", "clang-2100.3.35.1" },
            { "Target: arm64", "Target: x86_64" },
            { "InstalledDir: /Library", "InstalledDir: /OtherLibrary" },
            { "/sdk/include", "/other-sdk/include" },
            { "LLVM 21%.0%.0", "LLVM 22.0.0" },
            { '"arm64%-apple%-darwin"', '"x86_64-apple-darwin"' },
        }) do
            local changed = identity("/repository", function(descriptor)
                descriptor.banner = descriptor.banner:gsub(replacement[1], replacement[2])
            end)
            assert.is_not.equal(first, changed)
        end
        assert.is_not.equal(first, (identity("/repository", function(descriptor)
            descriptor.preprocessor_identity = "#define __COMPILER_VERSION__ 2\n"
        end)))
        assert.is_not.equal(first, (identity("/repository", nil, 2)))
        assert.is_not.equal(first, (identity("/repository", function(_, ctx)
            local stat = ctx.io.stat
            function ctx.io:stat(path)
                local result, err = stat(self, path)
                if result and path == native_tool("as") then result.changed_seconds = result.changed_seconds + 1 end
                return result, err
            end
        end)))
    end)

    it("shares only identical null-input compiler descriptions with the preprocessor", function()
        local ctx = native_context({ [native_tool("cc")] = "driver" })
        local null = require("titan-compiler.platform").windows and "NUL" or "/dev/null"
        function ctx.io:run(argv, options)
            self.commands[#self.commands + 1] = { argv = argv, capture = options.stderr_to_stdout }
            local macro = argv[#argv - 3] == "-E"
            return { started = true, ok = true,
                output = macro and ("#define VALUE " .. #self.commands .. "\n") or "clang version 22.1.8 vendor" }
        end
        local macros = { native_tool("cc"), "-dM", "-E", "-x", "c", null }
        local banner = { native_tool("cc"), "-E", "-v", "-x", "c", null, "-o", null }
        assert(cpp.cached_command(macros, false, ctx.io))
        assert(cpp.cached_command(banner, true, ctx.io))
        assert(incremental.toolchain_identity(ctx, { compiler_argv = { native_tool("cc") }, stage_tools = {} }))
        assert.equal(2, #ctx.io.commands)
        local effective = { native_tool("cc"), "-O2", "-dM", "-E", "-x", "c", null }
        assert(cpp.cached_command(effective, false, ctx.io))
        assert.equal(3, #ctx.io.commands)
        assert(cpp.cached_command(macros, true, ctx.io))
        assert.equal(4, #ctx.io.commands)
        local forced = { native_tool("cc"), "-include", fixture_path("/forced.h"), "-dM", "-E", "-x", "c", null }
        assert(cpp.cached_command(forced, false, ctx.io))
        assert(cpp.cached_command(forced, false, ctx.io))
        assert.equal(6, #ctx.io.commands)
        local other = context({})
        other.io.run = ctx.io.run
        assert(cpp.cached_command(macros, false, other.io))
        assert.equal(1, #other.io.commands)
    end)

    for _, command in ipairs({
        { native_tool("lua"), fixture_path("/wrappers/compiler script.lua") },
        { native_tool("sh"), fixture_path("/wrappers/compiler script.sh") },
    }) do
        it("preserves the complete " .. command[1] .. " wrapper command in toolchain probes", function()
            local ctx = native_context({ [command[1]] = "interpreter",
                [native_tool("cc1")] = "compiler stage", [native_tool("as")] = "assembler" })
            local null = require("titan-compiler.platform").windows and "NUL" or "/dev/null"
            local function expected(tail)
                local argv = { table.unpack(command) }
                for _, value in ipairs(tail) do argv[#argv + 1] = value end
                return argv
            end
            function ctx.io:run(argv)
                self.commands[#self.commands + 1] = argv
                if argv[#command + 1] == "-dM" then
                    assert.same(expected({ "-dM", "-E", "-x", "c", null }), argv)
                    return { started = true, ok = true, output = "#define __COMPILER_VERSION__ 1\n" }
                elseif argv[#command + 1] == "-E" then
                    assert.same(expected({ "-E", "-v", "-x", "c", null, "-o", null }), argv)
                    return { started = true, ok = true, output = "gcc compiler wrapper" }
                end
                local stage = argv[#argv]:match("^-print%-prog%-name=(.*)$")
                assert.is_not_nil(stage)
                assert.same(expected({ "-O2", "-print-prog-name=" .. stage }), argv)
                return { ok = true, output = native_tool(stage) .. "\n" }
            end
            local descriptor = { compiler_argv = command, compile_flags = { "-O2" } }
            local digest, details, status = incremental.toolchain_identity(ctx, descriptor)
            if platform.windows then
                assert.is_nil(digest)
                assert.is_string(details)
                assert.equal("uncertified", status)
                assert.equal(4, #ctx.io.commands)
                local repeated, reason, repeated_status = incremental.toolchain_identity(ctx, descriptor)
                assert.is_nil(repeated)
                assert.is_string(reason)
                assert.equal("uncertified", repeated_status)
                assert.equal(6, #ctx.io.commands)
            else
                assert.equal(3, #details.tools)
                assert.equal(command[1], details.tools[1].path)
                assert.equal(digest, incremental.toolchain_identity(ctx, descriptor))
                assert.equal(4, #ctx.io.commands)
            end
            assert.equal(0, incremental.counters(ctx).file_hashes)
            assert.is_nil(ctx.io.reads[command[2]])
        end)
    end

    it("keeps explicit wrapper-stage certification separate from an unknown producer policy", function()
        local ctx = native_context({ [native_tool("ccache")] = "wrapper", [native_tool("gcc")] = "driver",
            [native_tool("cc1")] = "compiler stage", [native_tool("as")] = "assembler" })
        function ctx.io:run(argv)
            self.commands[#self.commands + 1] = argv
            local name = argv[#argv]:match("^-print%-prog%-name=(.*)$")
            assert.is_not_nil(name)
            return { ok = true, output = native_tool(name) .. "\n" }
        end
        local descriptor = { compiler_argv = { native_tool("ccache"), native_tool("gcc") },
            preprocessor_identity = "macros", banner = "gcc version vendor" }
        local digest, details, status = incremental.toolchain_identity(ctx, descriptor)
        if platform.windows then
            assert.is_nil(digest)
            assert.is_string(details)
            assert.equal("uncertified", status)
            local repeated, reason, repeated_status = incremental.toolchain_identity(ctx, descriptor)
            assert.is_nil(repeated)
            assert.is_string(reason)
            assert.equal("uncertified", repeated_status)
            assert.equal(0, #ctx.io.commands)
        else
            assert.equal(4, #details.tools)
            assert.equal(digest, incremental.toolchain_identity(ctx, descriptor))
            assert.equal(2, #ctx.io.commands)
        end
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
        assert.is_nil(first.io.reads[native_tool("cc")])
        assert.is_nil(second.io.reads[native_tool("cc")])
    end)

    it("reports inventory errors and preserves cancellation values", function()
        local ctx, files = configured()
        files[fixture_path("/real/titanc")] = nil
        local ok, err = pcall(incremental.configuration, ctx)
        assert.is_false(ok)
        assert.matches("cannot certify compiler configuration:", err, 1, true)
        local cancelled = {}
        local other = configured()
        function other.io:list() error(cancelled, 0) end
        local success, failure = pcall(incremental.configuration, other)
        assert.is_false(success); assert.equal(cancelled, failure)
    end)

    it("fails certification on a failing preamble probe and removes its dependency file", function()
        local ctx, files = configured()
        function ctx.io:run(argv)
            self.commands[#self.commands + 1] = argv
            return { ok = false, diagnostic = "cc: error: unrecognized command-line option" }
        end
        local ok, err = pcall(incremental.configuration, ctx)
        assert.is_false(ok)
        assert.equal("cannot certify compiler configuration: cc: error: unrecognized command-line option", err)
        assert.equal(1, #ctx.io.commands)
        assert.is_nil(files[fixture_path("/") .. "temporary.d"])
        assert.is_nil(ctx.incremental_configuration)
    end)

    it("fails closed when no POSIX PATH entry holds an executable tool", function()
        with_posix_search("/ambient", function()
            local ctx = posix_search_context("cc")
            ctx.executable_path = "/nowhere:/later"
            -- /later/cc exists but this process may not execute it.
            function ctx.io:executable() return false end
            local ok, err = pcall(incremental.physical_executable, ctx, "cc")
            assert.is_false(ok)
            assert.equal("cannot resolve native tool executable: cc", err)
            assert.same({}, ctx.io.reads)
        end)
    end)
end)

describe("incremental dependency verdicts", function()
    local function imported(source_required)
        local cert = certificate()
        cert.imports = { { name = "producer", source_required = source_required == true,
            view = source_required and "source" or "public", interface = "same" } }
        cert.bindings = { producer = "handle" }
        cert.providers = { producer = fixture_path("/sdk/producer.so") }
        return record(cert)
    end

    it("accepts an unchanged semantic interface despite a rebuilt producer", function()
        assert.same({ status = "hit" }, incremental.verdict(imported(),
            plan({ producer = "same" }, nil, { producer = fixture_path("/sdk/producer.so") })))
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
                { producer = fixture_path("/sdk/producer.so") })))
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
            plan(current, nil, { producer = fixture_path("/sdk/replacement.so") })).reason)
        local saved = imported()
        saved.object_metadata.certificate.bindings.producer = "global"
        assert.equal("import-binding", incremental.verdict(saved,
            plan(current, nil, { producer = fixture_path("/sdk/producer.so") })).reason)
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
                { producer = fixture_path("/sdk/producer.so") })).status)
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
        local ctx, files = context({ [fixture_path("/out/main.o")] = "object", [fixture_path("/out/main.c")] = "generated",
            [fixture_path("/src/main.titan")] = "source" })
        ctx.incremental_configuration = configuration()
        ctx.incremental_options = { stem = function() return fixture_path("/out/main") end,
            codegen_options = function() return certificate().codegen end }
        local saved = record()
        objectmetadata.read = function() return saved end
        staticmetadata.scan_bytes = function() return { kind = "object", fingerprint = {} } end
        local source = { kind = "flat", main = fixture_path("/src/main.titan"),
            files = { fixture_path("/src/main.titan") } }
        return ctx, saved, source, files
    end

    it("returns the primary and ordered validated object inventory without native commands", function()
        local ctx, _, source = fixture()
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("hit", result.status)
        assert.equal(fixture_path("/out/main.o"), result.object)
        assert.same({ fixture_path("/out/main.o") }, result.objects)
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

    for _, case in ipairs({
        { "compiler", { "compiler", "toolchain", "options", "preamble" } },
        { "toolchain", { "toolchain", "options", "preamble" } },
        { "options", { "options", "preamble" } },
        { "preamble", { "preamble" } },
    }) do
        it("reports configuration " .. case[1] .. " before its dependent components", function()
            local ctx, saved, source = fixture()
            for _, component in ipairs(case[2]) do
                saved.object_metadata.certificate.configuration[component] = "old"
            end
            local result = incremental.certify_local(ctx, "main", source)
            assert.equal("configuration", result.reason)
            assert.equal(case[1], result.detail)
            assert.same({}, result.imports)
        end)
    end

    it("detects same-time source content edits and exact folder addition and removal", function()
        local ctx, _, source, files = fixture()
        files[fixture_path("/src/main.titan")] = "edited"
        local changed = incremental.certify_local(ctx, "main", source)
        assert.equal("source-content", changed.reason); assert.equal(fixture_path("/src/main.titan"), changed.detail)
        assert.is_nil(changed.imports)
        local added, _, folder, more = fixture()
        more[fixture_path("/src/extra.titan")] = "extra"
        folder.kind, folder.files[2] = "folder", fixture_path("/src/extra.titan")
        local addition = incremental.certify_local(added, "main", folder)
        assert.equal("source-set", addition.reason); assert.equal("added " .. fixture_path("/src/extra.titan"), addition.detail)
        local removed, saved, single = fixture()
        saved.object_metadata.certificate.sources[2] = { path = fixture_path("/src/old.titan"), sha256 = "old" }
        local removal = incremental.certify_local(removed, "main", single)
        assert.equal("source-set", removal.reason); assert.equal("removed " .. fixture_path("/src/old.titan"), removal.detail)
    end)

    it("classifies envelope absence and output movement", function()
        local ctx, _, source, files = fixture()
        files[fixture_path("/out/main.o")] = nil
        assert.equal("no-object", incremental.certify_local(ctx, "main", source).reason)
        local old, _, old_source = fixture()
        objectmetadata.read = function() return nil, "old schema", "record-schema" end
        assert.equal("record-schema", incremental.certify_local(old, "main", old_source).reason)
        local moved, saved, moved_source = fixture()
        saved.object_metadata.certificate.stem = fixture_path("/old/main")
        assert.equal("output-moved", incremental.certify_local(moved, "main", moved_source).reason)
    end)

    it("rejects obsolete envelope canonicalization before certifying sources", function()
        local ctx, _, source = fixture()
        local payload = "return {abi=" .. string.format("%q", version.TITAN_ABI_VERSION)
            .. ",schema=" .. string.format("%q", version.OBJECT_RECORD_SCHEMA)
            .. ",digest=" .. string.format("%q", version.CERTIFICATE_DIGEST)
            .. ",canonicalization='obsolete',entry={}}"
        objectmetadata.read = function() return objectmetadata.decode(payload) end
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("record-schema", result.reason)
        assert.matches("canonicalization=obsolete", result.detail, 1, true)
        assert.is_nil(result.imports)
        assert.is_nil(ctx.io.reads[fixture_path("/src/main.titan")])
    end)

    it("checks descriptor search inputs before restoring any graph", function()
        local ctx, saved, source = fixture()
        saved.ffi_header_descriptor = { search_inputs = {
            { kind = "search", path = fixture_path("/sdk/header.h"), identity = "old" } } }
        local calls = 0
        cpp.revalidate_header_input = function(input)
            calls = calls + 1
            return input, nil, true, "candidate"
        end
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("c-input", result.reason); assert.equal(fixture_path("/sdk/header.h") .. ": candidate", result.detail)
        assert.equal(1, calls)
        assert.same({}, result.imports)
        assert.is_nil(saved.compiled)
    end)

    it("checks split-part and coverage artifact completeness", function()
        local ctx, saved, source, files = fixture()
        local native = saved.object_metadata
        native.parts[2] = { index = 1, c_suffix = ".part1.c", object_suffix = ".part1.o" }
        native.private_header = ".priv.h"
        files[fixture_path("/out/main.part1.c")], files[fixture_path("/out/main.priv.h")] = "generated part", "private header"
        local result = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", result.reason)
        assert.matches(fixture_path("/out/main.part1.o"), result.detail, 1, true)
        local covered, cover_record, cover_source, cover_files = fixture()
        cover_record.object_metadata.coverage = { enabled = true, files = { fixture_path("/out/main.c") } }
        local missing = incremental.certify_local(covered, "main", cover_source)
        assert.equal("coverage-artifacts", missing.reason)
        assert.equal(fixture_path("/out/main.gcno"), missing.detail)
        cover_files[fixture_path("/out/main.gcno")] = "coverage notes"
        assert.equal("hit", incremental.certify_local(covered, "main", cover_source).status)
    end)

    it("requires the recorded generated C and private-header companions", function()
        local ctx, saved, source, files = fixture()
        local native = saved.object_metadata
        native.parts[2] = { index = 1, c_suffix = ".part1.c", object_suffix = ".part1.o" }
        native.private_header = ".priv.h"
        files[fixture_path("/out/main.part1.o")] = "part object"
        local missing_c = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", missing_c.reason)
        assert.matches(fixture_path("/out/main.part1.c"), missing_c.detail, 1, true)
        files[fixture_path("/out/main.part1.c")] = "generated part"
        local missing_h = incremental.certify_local(ctx, "main", source)
        assert.equal("parts", missing_h.reason)
        assert.matches(fixture_path("/out/main.priv.h"), missing_h.detail, 1, true)
    end)

    it("uses precise source digests and cached content-only sidecar scan facts", function()
        local ctx, saved, source, files = fixture()
        local part = fixture_path("/out/main.part1.o")
        files[part], files[fixture_path("/out/main.part1.c")], files[fixture_path("/out/main.priv.h")] =
            "sidecar object", "generated part", "private header"
        saved.object_metadata.parts[2] = { index = 1, c_suffix = ".part1.c", object_suffix = ".part1.o" }
        saved.object_metadata.private_header = ".priv.h"
        ctx.io = precise_context(files).io
        objectmetadata.read = function(_, path)
            if path == fixture_path("/out/main.o") then return saved end
        end
        local scans = {}
        staticmetadata.scan_bytes = function(_, path)
            scans[path] = (scans[path] or 0) + 1
            return { kind = "object", fingerprint = {
                format = "coff", word_size = 64, endian = "little", machine = 0x8664 } }
        end
        assert(incremental.load_digest_cache(ctx, fixture_path("/out")))
        assert.equal("hit", incremental.certify_local(ctx, "main", source).status)
        assert(incremental.save_digest_cache(ctx))
        assert.equal(1, scans[part])
        local warm = precise_context(files)
        warm.incremental_configuration, warm.incremental_options =
            ctx.incremental_configuration, ctx.incremental_options
        local fresh_source = { kind = source.kind, main = source.main, files = source.files }
        assert(incremental.load_digest_cache(warm, fixture_path("/out")))
        assert.equal("hit", incremental.certify_local(warm, "main", fresh_source).status)
        assert.is_nil(warm.io.reads[part])
        assert.is_nil(warm.io.reads[fixture_path("/src/main.titan")])
        assert.equal(1, scans[part])
        assert.equal(0, incremental.counters(warm).file_hashes)
        assert.equal(3, incremental.counters(warm).observation_reuses)
    end)

    it("shares source object and C-input hash memos across certifications", function()
        local ctx, saved, source, files = fixture()
        files[fixture_path("/sdk/header.h")] = "header"
        saved.c_header_dependencies = { { kind = "file", path = fixture_path("/sdk/header.h"), identity = "header" } }
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
        files[fixture_path("/src/main.titan")] = "edited"
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

    it("classifies source layout changes and unreadable sources as source misses", function()
        local ctx, _, source = fixture()
        source.kind = "folder"
        local relaid = incremental.certify_local(ctx, "main", source)
        assert.equal("source-set", relaid.reason)
        assert.equal("added " .. fixture_path("/src/main.titan"), relaid.detail)
        local unreadable, _, unreadable_source, files = fixture()
        files[fixture_path("/src/main.titan")] = nil
        local missing = incremental.certify_local(unreadable, "main", unreadable_source)
        assert.equal("source-content", missing.reason)
        assert.equal(fixture_path("/src/main.titan"), missing.detail)
        assert.is_nil(missing.imports)
    end)

    it("rejects certificates that bind unknown modules or name another module", function()
        local ctx, saved, source = fixture()
        saved.object_metadata.certificate.bindings = { stranger = "direct" }
        local unknown = incremental.certify_local(ctx, "main", source)
        assert.equal("record-schema", unknown.reason)
        assert.equal("missing or invalid certificate", unknown.detail)
        local revalidated = incremental.revalidate_record(ctx, "main", source, saved)
        assert.equal("record-schema", revalidated.reason)
        assert.equal("missing or invalid certificate", revalidated.detail)
        local renamed, renamed_saved, renamed_source = fixture()
        renamed_saved.type = { name = "other" }
        local mismatch = incremental.certify_local(renamed, "main", renamed_source)
        assert.equal("record-schema", mismatch.reason)
        assert.equal("module name mismatch", mismatch.detail)
    end)

    it("misses an unreadable or invalid primary object and incomplete coverage notes", function()
        local ctx, _, source = fixture()
        local read_file = ctx.io.read_file
        function ctx.io:read_file(name, ...)
            if name == fixture_path("/out/main.o") then return nil, "permission denied" end
            return read_file(self, name, ...)
        end
        local unreadable = incremental.certify_local(ctx, "main", source)
        assert.equal("record-unreadable", unreadable.reason)
        assert.matches("permission denied", unreadable.detail, 1, true)
        for _, case in ipairs({
            { function() return nil, "truncated object header" end, "truncated object header" },
            { function() return { kind = "archive", fingerprint = {} } end, "invalid primary object" },
        }) do
            local scanned, _, scanned_source = fixture()
            staticmetadata.scan_bytes = case[1]
            local result = incremental.certify_local(scanned, "main", scanned_source)
            assert.equal("parts", result.reason)
            assert.equal(case[2], result.detail)
        end
        local covered, cover_record, cover_source = fixture()
        cover_record.object_metadata.coverage = { enabled = true }
        local notes = incremental.certify_local(covered, "main", cover_source)
        assert.equal("coverage-artifacts", notes.reason)
        assert.equal(fixture_path("/out/main.gcno"), notes.detail)
    end)

    it("classifies conflicting and unreadable C inputs and propagates their cancellation", function()
        local header = fixture_path("/sdk/header.h")
        local ctx, saved, source = fixture()
        saved.c_header_dependencies = { { kind = "file", path = header, identity = "first" } }
        saved.ffi_header_descriptor = { search_inputs = {
            { kind = "file", path = header, identity = "second" } } }
        cpp.revalidate_header_input = function() error("conflicting inputs must not be revalidated") end
        local conflict = incremental.certify_local(ctx, "main", source)
        assert.equal("c-input", conflict.reason)
        assert.equal(header .. ": content", conflict.detail)
        for _, case in ipairs({
            { header .. ": file changed while it was read", "changed-during-read" },
            { header .. ": file changed during build", "changed-during-read" },
            { "permission denied", "unreadable" },
        }) do
            local raced, raced_saved, raced_source = fixture()
            raced_saved.c_header_dependencies = { { kind = "file", path = header, identity = "header" } }
            cpp.revalidate_header_input = function() error(case[1], 0) end
            local result = incremental.certify_local(raced, "main", raced_source)
            assert.equal("c-input", result.reason)
            assert.equal(header .. ": " .. case[2], result.detail)
        end
        local cancelled = {}
        local interrupted, interrupted_saved, interrupted_source = fixture()
        interrupted_saved.c_header_dependencies = { { kind = "file", path = header, identity = "header" } }
        cpp.revalidate_header_input = function() error(cancelled, 0) end
        local ok, err = pcall(incremental.certify_local, interrupted, "main", interrupted_source)
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)
end)

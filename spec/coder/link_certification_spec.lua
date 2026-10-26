local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local certificate = require "titan-compiler.linkcertificate"
local incremental = require "titan-compiler.incremental"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
local util = require "titan-compiler.util"
local version = require "titan-compiler.version"

local function remove(path)
    local kind = lfs.symlinkattributes(path, "mode")
    if kind == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif kind then assert(os.remove(path)) end
end

local function context() return { io = compiler_io.new_sync() } end
local function write(path, bytes) assert(context().io:write_file(path, bytes)) end
local function escape(path) return path:gsub("%$", "$$"):gsub("([ #])", "\\%1") end
local function gnu_report(output, inputs)
    local phony = {}
    for _, filename in ipairs(inputs) do phony[#phony + 1] = filename .. ":\n" end
    return output .. ": \\\n  " .. table.concat(inputs, " \\\n  ") .. "\n\n" ..
        table.concat(phony, "\n")
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

-- Real fixture files with deliberately controlled precise observations. The
-- fake inode and mtime stay fixed across writes; only ctime advances, so a
-- same-size replacement exercises the ctime gate rather than an inode miss.
local function precise_model(root)
    local model = { root = root, ctime = {}, ids = {}, executables = {}, clock = 1000000000, sequence = 0 }
    local function key(path) return platform.windows and path:gsub("\\", "/") or path end
    function model:context()
        local strategy = compiler_io.new_sync()
        local stat, lstat, read_file = strategy.stat, strategy.lstat, strategy.read_file
        local write_file, rename = strategy.write_file, strategy.rename
        strategy.reads = {}
        local function decorate(metadata, err, path)
            if not metadata then return nil, err end
            path = key(path)
            if not model.ids[path] then
                model.sequence = model.sequence + 1
                model.ids[path] = tostring(model.sequence)
            end
            local changed = model.ctime[path] or 1000000000
            metadata.precision = model.coarse and "coarse" or "ns"
            metadata.time_precision = metadata.precision
            metadata.dev, metadata.ino = "1", model.ids[path]
            metadata.device, metadata.inode = 1, tonumber(model.ids[path])
            metadata.mtime_ns, metadata.ctime_ns = 1000000000, changed
            metadata.modified_seconds, metadata.modified_nanoseconds = 1, 0
            metadata.changed_seconds, metadata.changed_nanoseconds = changed // 1000000000, changed % 1000000000
            if model.executables[path] then metadata.mode = 0x81ed end
            return metadata
        end
        function strategy:stat(path)
            local metadata, err = stat(self, path)
            return decorate(metadata, err, path)
        end
        function strategy:lstat(path)
            local metadata, err = lstat(self, path)
            return decorate(metadata, err, path)
        end
        function strategy:read_file(path, bound)
            local name = key(path)
            self.reads[name] = (self.reads[name] or 0) + 1
            return read_file(self, path, bound)
        end
        local function changed(path)
            model.clock = model.clock + 1
            model.ctime[key(path)] = model.clock
        end
        function strategy:write_file(path, bytes)
            local ok, err = write_file(self, path, bytes)
            if ok then changed(path) end
            return ok, err
        end
        function strategy:rename(from, to)
            local ok, err = rename(self, from, to)
            if ok then changed(to) end
            return ok, err
        end
        local ctx = { io = strategy, incremental_configuration = { compiler = "test-compiler" } }
        assert(incremental.load_digest_cache(ctx, root))
        return ctx
    end
    return model
end

describe("final link certificates", function()
    local root, spec, previous_cwd
    local function prepare(overrides)
        local request = clone(spec)
        for key, value in pairs(overrides or {}) do request[key] = value end
        local ctx = context()
        return ctx, certificate.prepare(ctx, request)
    end
    local function commit(overrides)
        local ctx, ticket = prepare(overrides)
        assert(certificate.invalidate(ctx, ticket))
        assert(certificate.commit(ctx, ticket))
        return ticket
    end
    local function hit(overrides)
        local ctx, ticket = prepare(overrides)
        return certificate.check(ctx, ticket)
    end
    before_each(function()
        previous_cwd = assert(lfs.currentdir())
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        root = certificate.canonical_path(context(), root)
        for _, leaf in ipairs({ "main.o", "side.o", "helper.o", "payload.a", "provider.so", "runtime.a", "native.a", "program" }) do
            write(root .. "/" .. leaf, leaf .. " bytes")
        end
        write(root .. "/link.d", gnu_report(root .. "/program", { root .. "/native.a" }))
        spec = {
            output_root = root, roots = { "app.main", "app.extra" }, entry = { module = "app.main", main = "({string}):integer" },
            kind = "program", outputs = { { path = root .. "/program" } },
            objects = { root .. "/main.o", root .. "/side.o" }, c_objects = { root .. "/helper.o" },
            payloads = { root .. "/payload.a" }, providers = { root .. "/provider.so" },
            archives = { root .. "/runtime.a" }, runtime = { root .. "/runtime.a" },
            argv = { "-Lfirst", "-lone", "-ltwo", "-lone" }, toolchain = { compiler = "cc identity", linker = "ld identity" },
            test_cases = { { name = "app.test_one", owner = "app" } },
            templates = "runner+entrypoint template", coverage = { notes = { "main.gcno" } },
            companions = { manifest = "manifest recipe", dsym = false },
            native_libraries = { backend = "gnu", dependency_file = root .. "/link.d" },
        }
    end)
    after_each(function()
        assert(lfs.chdir(previous_cwd))
        remove(root)
    end)

    it("accepts an unchanged complete output set without rewriting it", function()
        local ticket = commit()
        local old = os.time() - 60
        assert(lfs.touch(root .. "/program", old, old))
        assert(lfs.touch(ticket.record, old, old))
        assert.is_true(hit())
        assert.equal(old, lfs.attributes(root .. "/program", "modification"))
        assert.equal(old, lfs.attributes(ticket.record, "modification"))
    end)

    it("reuses output recipes across physical-parent aliases and working-directory spellings", function()
        if platform.windows then pending("POSIX directory alias fixture"); return end
        local alias = root .. "/output alias"
        assert(lfs.link(root, alias, true))
        local target = root .. "/deliverables/bin/program"
        local original = clone(spec)
        original.output_root = alias
        original.argv = {}
        original.outputs = { { path = alias .. "/deliverables/bin/program" },
            { path = alias .. "/deliverables/bin/program.dSYM", kind = "directory" } }
        local cold_context = context()
        local cold = certificate.prepare(cold_context, original)
        assert.equal(target, cold.outputs[1].path)
        assert.equal(target .. ".dSYM", cold.outputs[2].path)
        assert(lfs.mkdir(root .. "/deliverables"))
        assert(lfs.mkdir(root .. "/deliverables/bin"))
        write(target, "new program bytes")
        assert(lfs.mkdir(target .. ".dSYM"))
        write(target .. ".dSYM/debug", "DWARF bytes")
        assert(certificate.commit(cold_context, cold))

        local relative = clone(spec)
        relative.output_root = "."
        relative.argv = {}
        relative.outputs = { { path = "./deliverables/bin/program" },
            { path = "./deliverables/bin/program.dSYM", kind = "directory" } }
        local warm_context = context()
        assert(lfs.chdir(root))
        local warm = certificate.prepare(warm_context, relative)
        assert.equal(cold.key, warm.key)
        assert.equal(cold.directory, warm.directory)
        assert.equal(cold.input, warm.input)
        assert.is_true(certificate.check(warm_context, warm))
        local record = assert(certificate.read_record(warm_context, warm.record))
        assert.equal(target, record.outputs[1].path)
        assert.equal(target .. ".dSYM/debug", record.outputs[2].entries[1].path)
    end)

    it("does not reuse a certified target through a substituted output leaf symlink", function()
        if platform.windows then pending("POSIX symlink fixture"); return end
        local original = commit()
        local alias = root .. "/program-alias"
        assert(lfs.link(root .. "/program", alias, true))
        local ctx, ticket = prepare({ outputs = { { path = alias } } })
        assert.equal(original.key, ticket.key)
        assert.equal(alias, ticket.outputs[1].path)
        assert.is_false(certificate.check(ctx, ticket))
    end)

    for _, field in ipairs({ "objects", "c_objects", "payloads", "providers", "archives", "runtime" }) do
        it("invalidates changed " .. field .. " bytes without relying on timestamps", function()
            commit()
            local path = spec[field][1]
            local old = lfs.attributes(path, "modification")
            write(path, "replacement bytes")
            assert(lfs.touch(path, old, old))
            assert.is_false(hit())
        end)
    end

    it("preserves ordered roots, object parts, payloads and repeated link arguments", function()
        spec.payloads = { root .. "/payload.a", root .. "/runtime.a" }
        commit()
        for _, field in ipairs({ "roots", "objects", "payloads", "argv" }) do
            local reordered = clone(spec[field])
            reordered[1], reordered[2] = reordered[2], reordered[1]
            assert.is_false(hit({ [field] = reordered }), field)
        end
    end)

    for _, field in ipairs({ "entry", "toolchain", "test_cases", "templates", "coverage", "companions", "bindings", "environment", "target", "policy" }) do
        it("certifies the " .. field .. " recipe", function()
            commit()
            assert.is_false(hit({ [field] = { changed = true } }))
        end)
    end

    it("distinguishes bootstrap policy and executable/provider output kinds", function()
        commit()
        assert.is_false(hit({ no_uv_bootstrap = true }))
        assert.is_false(hit({ kind = "provider-pair" }))
    end)

    it("rejects missing and modified final outputs", function()
        commit()
        write(root .. "/program", "tampered")
        assert.is_false(hit())
        assert(os.remove(root .. "/program"))
        assert.is_false(hit())
    end)

    it("rejects output symlink substitution even when the target bytes match", function()
        if platform.windows then pending("POSIX symlink fixture"); return end
        commit()
        assert(os.rename(root .. "/program", root .. "/original"))
        assert(lfs.link(root .. "/original", root .. "/program", true))
        assert.is_false(hit())
    end)

    it("requires the executable bit and certifies mode changes", function()
        if platform.windows then pending("POSIX executable permissions"); return end
        local io = context().io
        assert(io:run({ "chmod", "755", root .. "/program" }).ok)
        spec.outputs[1].executable = true
        commit()
        assert(io:run({ "chmod", "644", root .. "/program" }).ok)
        assert.is_false(hit())
    end)

    it("validates complete directory companions and missing members", function()
        assert(lfs.mkdir(root .. "/program.dSYM"))
        write(root .. "/program.dSYM/debug", "DWARF bytes")
        spec.outputs[#spec.outputs + 1] = { path = root .. "/program.dSYM", kind = "directory" }
        commit()
        assert.is_true(hit())
        assert(os.remove(root .. "/program.dSYM/debug"))
        assert.is_false(hit())
    end)

    it("orders output-set keys and directory members bytewise across locales", function()
        local directory = root .. "/companion"
        assert(lfs.mkdir(directory))
        for _, name in ipairs({ "z", "A", "é" }) do write(directory .. "/" .. name, name) end
        write(root .. "/z-image", "z image")
        write(root .. "/é-image", "accented image")
        spec.outputs = { { path = directory, kind = "directory" },
            { path = root .. "/é-image" }, { path = root .. "/z-image" } }
        local saved_locale = os.setlocale(nil, "collate")
        local ok, err = pcall(function()
            assert(os.setlocale("C", "collate"))
            local ticket = commit()
            local expected_keys = {}
            for _, output in ipairs(spec.outputs) do
                expected_keys[#expected_keys + 1] = certificate.canonical_path(context(), output.path)
            end
            table.sort(expected_keys, util.bytewise_less)
            assert.equal(incremental.digest(context(), "final-output-set", expected_keys), ticket.key)
            local record = assert(certificate.read_record(context(), ticket.record))
            local names = {}
            for _, member in ipairs(record.outputs[1].entries) do names[#names + 1] = member.path end
            assert.same({ directory .. "/A", directory .. "/z", directory .. "/é" }, names)
            for _, locale in ipairs({ "en_US.UTF-8", "pt_BR.UTF-8", "C.UTF-8" }) do
                if os.setlocale(locale, "collate") then
                    local ctx, next_ticket = prepare()
                    assert.equal(ticket.key, next_ticket.key)
                    assert.is_true(certificate.check(ctx, next_ticket))
                end
            end
        end)
        if saved_locale then assert(os.setlocale(saved_locale, "collate")) end
        assert.is_true(ok, tostring(err))
    end)

    it("rehashes actual linker-reported libraries and scripts on a hit", function()
        commit()
        write(root .. "/native.a", "new native library bytes")
        local accepted, reason = hit()
        assert.is_false(accepted)
        assert.equal("native libraries changed", reason)
    end)

    it("reads GNU linker literal paths with spaces and Make punctuation", function()
        local library = root .. (platform.windows and "/native Ω #$ data.a" or "/native Ω #$ :back\\slash.a")
        write(library, "literal library path")
        write(root .. "/link.d", gnu_report(root .. "/target with spaces", {
            library, root .. "/native.a", library,
        }))
        local ticket = commit()
        local record = assert(certificate.read_record(context(), ticket.record))
        assert.equal(2, #record.native)
        assert.equal(library, record.native[1].path)
        assert.is_true(hit())
        write(library, "replacement library bytes")
        assert.is_false(hit())
    end)

    it("reads LLD escaped Make dependency paths independently of GNU ld reports", function()
        local library = root .. "/native Ω #$ data.a"
        write(library, "escaped library path")
        spec.native_libraries.backend = "lld"
        write(root .. "/link.d", escape(root .. "/target with spaces") .. ": " .. escape(library) ..
            "\n" .. escape(library) .. ":\n")
        commit()
        assert.is_true(hit())
        write(library, "replacement library bytes")
        assert.is_false(hit())
    end)

    it("reads Darwin dependency-info inputs without treating output records as inputs", function()
        spec.native_libraries.backend = "darwin"
        write(root .. "/link.d", "\0ld64\0\16" .. root .. "/native.a\0\17missing-library\0\64stage-image\0")
        commit()
        assert.is_true(hit())
        write(root .. "/native.a", "replacement")
        assert.is_false(hit())
    end)

    it("keeps unsupported native mechanisms explicitly uncacheable", function()
        spec.native_libraries.backend = "opaque"
        local ctx, ticket = prepare()
        assert.is_false(ticket.cacheable)
        assert(certificate.commit(ctx, ticket))
        assert.is_nil(lfs.attributes(ticket.record))
        assert.is_false(certificate.check(ctx, ticket))
    end)

    it("separates synthetic targets sharing the same first root", function()
        local _, first = prepare()
        local _, second = prepare({ outputs = { { path = root .. "/other-program" } } })
        assert.not_equal(first.key, second.key)
        assert.not_equal(first.synthetic_directory, second.synthetic_directory)
        local _, reordered = prepare({ roots = { "different-first-root" } })
        assert.equal(first.key, reordered.key)
        assert.not_equal(first.input, reordered.input)
    end)

    it("removes the old marker before an interrupted or failed publication", function()
        commit()
        local ctx, ticket = prepare()
        assert(certificate.invalidate(ctx, ticket))
        write(root .. "/program", "partial replacement")
        assert.is_false(hit())
        assert.is_nil(lfs.attributes(ticket.record))
        commit()
        assert.is_true(hit())
    end)

    it("does not commit when a linked object changes during publication", function()
        local ctx, ticket = prepare()
        write(root .. "/main.o", "changed after preparation")
        assert.has_error(function() certificate.commit(ctx, ticket) end,
            "link input changed during build: objects")
        assert.is_nil(lfs.attributes(ticket.record))
    end)

    it("treats old, malformed and extended record schemas as misses", function()
        local ticket = commit()
        local ctx = context()
        local record = assert(certificate.read_record(ctx, ticket.record))
        record.schema = "old"
        assert(certificate.write_record(ctx, ticket.record, record))
        assert.is_false(hit())
        record.schema = version.TITAN_LINK_RECORD_SCHEMA
        record.unknown = true
        assert(certificate.write_record(ctx, ticket.record, record))
        assert.is_false(hit())
        record.unknown = nil
        record.outputs[1].entries = record.outputs
        assert(certificate.write_record(ctx, ticket.record, record))
        assert.is_false(hit())
        write(ticket.record, "return os.execute('untrusted cache')")
        assert.is_false(hit())
    end)

    it("propagates non-string cancellation from file certification", function()
        commit()
        local signal = {}
        local ctx, ticket = prepare()
        ctx.io.read_file = function() error(signal, 0) end
        local ok, err = pcall(certificate.check, ctx, ticket)
        assert.is_false(ok)
        assert.equal(signal, err)
    end)
end)

describe("final link certification through the CLI", function()
    local root, frontend, log, prefix, lua, repository
    local function read(path)
        local file = io.open(path, "rb")
        if not file then return "" end
        local bytes = assert(file:read("a")); assert(file:close())
        return bytes
    end
    local function compile(arguments, expected)
        local argv = { "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_ROCKS_ROOT=" .. prefix, "TITAN_EXTRA_CPPFLAGS=",
            "TITAN_EXTRA_CFLAGS=-O0 -fno-lto", "TITAN_EXTRA_LDFLAGS=-fno-lto",
            lua, "-E", frontend, "--incremental", "--tree", root, "--output", root .. "/out" }
        for _, value in ipairs(arguments) do argv[#argv + 1] = value end
        local result = context().io:run(argv)
        assert.equal(expected ~= false, result.started and result.ok, result.output or result.diagnostic)
        return result.output or ""
    end
    local function exe(name) return root .. "/" .. name .. (platform.windows and ".exe" or "") end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        repository = assert(lfs.currentdir())
        prefix = require("spec.support.installed_prefix").active()
        lua = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")
        frontend, log = root .. "/frontend.lua", root .. "/final-work"
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
local log = %q
local function trace(owner, key)
    local original = assert(owner[key])
    owner[key] = function(...)
        local file = assert(io.open(log, "a"))
        assert(file:write(key, "\n")); assert(file:close())
        return original(...)
    end
end
local driver = require "titan-compiler.driver"
for _, key in ipairs({ "compile_program", "run_standalone_archive_probe", "link_provider_pair", "run_link_command" }) do trace(driver, key) end
trace(require "titan-compiler.test_runner", "render")
dofile(%q .. "/titanc")
]], repository, repository, platform.windows and ".dll" or ".so", log, repository))
        write(root .. "/app.titan", "function main(args: {string}): integer return 0 end\n")
    end)
    after_each(function() remove(root) end)

    it("skips all final native work on a repeated executable build", function()
        compile({ "--exe", exe("program Ω"), "app" })
        assert.not_equal("", read(log))
        local old = os.time() - 60
        assert(lfs.touch(exe("program Ω"), old, old))
        write(log, "")
        compile({ "--exe", exe("program Ω"), "app" })
        assert.equal("", read(log))
        assert.equal(old, lfs.attributes(exe("program Ω"), "modification"))
    end)

    it("skips runner generation on a repeated test image and separates final targets", function()
        write(root .. "/checks.titan", 'local test = import "test"\nfunction test_case(context: test.Context) test.assert(true) end\n')
        compile({ "--test", "--exe", exe("tests-one"), "checks" })
        assert.matches("render", read(log), 1, true)
        write(log, "")
        compile({ "--test", "--exe", exe("tests-one"), "checks" })
        assert.equal("", read(log))
        compile({ "--test", "--exe", exe("tests-two"), "checks" })
        assert.matches("render", read(log), 1, true)
        write(log, "")
        compile({ "--test", "--exe", exe("tests-one"), "checks" })
        assert.equal("", read(log))
        write(root .. "/checks.titan", 'local test = import "test"\nfunction test_other(context: test.Context) test.assert(true) end\n')
        compile({ "--test", "--exe", exe("tests-one"), "checks" })
        assert.matches("render", read(log), 1, true)
    end)

    it("compiles C-only helpers and links ordered native inputs without rebuilding Titan consumers", function()
        write(root .. "/helper.h", "int helper(void);\n")
        write(root .. "/helper.c", "int helper(void) { return VALUE; }\n")
        write(root .. "/app.titan", 'foreign import "helper.h"\nfunction main(args: {string}): integer return ffi.helper() as integer end\n')
        local arguments = { "-DVALUE=1", "--cflag=-UVALUE", "-DVALUE=2",
            "--c-source", root .. "/helper.c", "--exe", exe("native-program"), "app" }
        compile(arguments)
        local result = context().io:run({ exe("native-program") })
        assert.equal(2, result.status, result.output)
        local object = root .. "/out/app.o"
        local old = os.time() - 60
        assert(lfs.touch(object, old, old))
        write(log, "")
        compile(arguments)
        assert.equal("", read(log))
        write(root .. "/helper.c", "int helper(void) { return VALUE + 1; }\n")
        compile(arguments)
        assert.matches("compile_program", read(log), 1, true)
        assert.equal(old, lfs.attributes(object, "modification"))
        result = context().io:run({ exe("native-program") })
        assert.equal(3, result.status, result.output)
        compile({ "-c", "--c-source", root .. "/helper.c", "-DVALUE=2" })
    end)

    it("preserves the previous POSIX executable and dSYM after a partial failed link", function()
        if platform.windows then pending("POSIX executable staging"); return end
        compile({ "--exe", exe("program"), "app" })
        local previous = read(exe("program"))
        local modified = lfs.attributes(exe("program"), "modification")
        local function snapshot(directory)
            local result = {}
            local function visit(path, relative)
                local kind = lfs.symlinkattributes(path, "mode")
                if kind == "directory" then
                    result[relative] = { kind = kind }
                    for name in lfs.dir(path) do
                        if name ~= "." and name ~= ".." then visit(path .. "/" .. name, relative .. "/" .. name) end
                    end
                elseif kind then result[relative] = { kind = kind, bytes = read(path) } end
            end
            visit(directory, "")
            return result
        end
        local dsym = snapshot(exe("program") .. ".dSYM")
        if require("titan-compiler.driver").IS_DARWIN then
            assert.equal("directory", lfs.attributes(exe("program") .. ".dSYM", "mode"))
        end
        local original_frontend = frontend
        frontend = root .. "/partial-link.lua"
        local stage_log = root .. "/partial-output"
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local driver = require "titan-compiler.driver"
local program, link = driver.compile_program, driver.run_link_command
local in_program = false
driver.compile_program = function(...)
    in_program = true
    local result = table.pack(program(...))
    in_program = false
    return table.unpack(result, 1, result.n)
end
driver.run_link_command = function(argv, ...)
    if not in_program then return link(argv, ...) end
    local output
    for index, argument in ipairs(argv) do if argument == "-o" then output = argv[index + 1] end end
    assert(output)
    local file = assert(io.open(output, "wb"))
    assert(file:write("partial failed native image")); assert(file:close())
    file = assert(io.open(%q, "wb"))
    assert(file:write(output)); assert(file:close())
    return nil, "exit", 86
end
dofile(%q)
]], repository, stage_log, original_frontend))
        write(root .. "/app.titan", "function main(args: {string}): integer return 1 end\n")
        compile({ "--exe", exe("program"), "app" }, false)
        local staged = read(stage_log)
        assert.not_equal("", staged)
        assert.not_equal(exe("program"), staged)
        assert.equal(previous, read(exe("program")))
        assert.equal(modified, lfs.attributes(exe("program"), "modification"))
        assert.same(dsym, snapshot(exe("program") .. ".dSYM"))
        assert.is_nil(lfs.symlinkattributes(staged))
        local stage_directory = staged:match("^(.*%.stage%.tmp%.[^/]+)/[^/]+$")
        if stage_directory then assert.is_nil(lfs.symlinkattributes(stage_directory)) end
        frontend = original_frontend
        compile({ "--exe", exe("program"), "app" })
    end)

    it("retries a failed link from reusable module objects", function()
        compile({ "--exe", exe("program"), "app" })
        local object = root .. "/out/app.o"
        local old = os.time() - 60
        assert(lfs.touch(object, old, old))
        compile({ "--ldflag=-lmissing_titan_link_fixture_303", "--exe", exe("program"), "app" }, false)
        write(log, "")
        compile({ "--exe", exe("program"), "app" })
        assert.matches("compile_program", read(log), 1, true)
        assert.equal(old, lfs.attributes(object, "modification"))
        write(log, "")
        compile({ "--exe", exe("program"), "app" })
        assert.equal("", read(log))
    end)
end)

describe("native library coverage policy", function()
    local root
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        write(root .. "/libfirst.a", "archive bytes")
        write(root .. "/libsecond.a", "other archive bytes")
    end)
    after_each(function() remove(root) end)

    it("falls back to compiler-resolved paths when dependency output is unavailable", function()
        local ctx, calls = context(), {}
        ctx.io.run = function(_, argv)
            calls[#calls + 1] = argv[#argv]
            local library = argv[#argv]:match("=(.+)$")
            if library == "libfirst.so" then
                return { started = true, ok = true, output = library .. "\n" }
            end
            return { started = true, ok = true, output = root .. "/" .. library .. "\n" }
        end
        local policy = certificate.native_library_policy(ctx, {
            backend = "none", compiler_argv = { "selected-cc" }, argv = { "-lfirst" },
        })
        assert.is_true(policy.cacheable)
        assert.equal("compiler", policy.backend)
        assert.same({ root .. "/libfirst.a" }, policy.files)
        assert.same({ "-print-file-name=libfirst.so", "-print-file-name=libfirst.a" }, calls)
    end)

    it("retains static and dynamic library selection in ordered fallback arguments", function()
        local policy = certificate.native_library_policy(context(), {
            compiler_argv = { "selected-cc" }, argv = {
                "-L" .. root, "-Wl,-Bstatic", "-lfirst", "-Wl,-Bdynamic", "-lsecond", "-lfirst",
            },
        })
        assert.is_true(policy.cacheable)
        assert.same({ root .. "/libfirst.a", root .. "/libsecond.a", root .. "/libfirst.a" }, policy.files)
    end)

    it("makes unsupported response and plugin mechanisms explicitly uncacheable", function()
        for _, flag in ipairs({ "@response", "-Wl,@response", "-Wl,-plugin,plugin.so" }) do
            local policy = certificate.native_library_policy(context(), {
                backend = "gnu", dependency_file = root .. "/link.d", argv = { flag },
            })
            assert.is_false(policy.cacheable)
            assert.matches("opaque linker input mechanism", policy.reason, 1, true)
        end
    end)
end)

describe("persistent precise file certification", function()
    local root, model, spec, bulk
    local function saved(context)
        assert(incremental.save_digest_cache(context))
        return context
    end
    local function seed()
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, spec)
        assert(certificate.commit(ctx, ticket))
        saved(ctx)
        return ticket
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        root = certificate.canonical_path(context(), root)
        model = precise_model(root)
        bulk = { "main.o", "helper.o", "payload.a", "provider.so", "archive.a", "runtime.o", "native.a", "program" }
        for _, leaf in ipairs(bulk) do write(root .. "/" .. leaf, leaf .. " bytes") end
        write(root .. "/link.d", gnu_report(root .. "/program", { root .. "/native.a" }))
        spec = { output_root = root, roots = { "app" }, kind = "program", templates = "template",
            toolchain = "toolchain", argv = {}, outputs = { { path = root .. "/program" } },
            objects = { root .. "/main.o" }, c_objects = { root .. "/helper.o" },
            payloads = { root .. "/payload.a" }, providers = { root .. "/provider.so" },
            archives = { root .. "/archive.a" }, runtime = { root .. "/runtime.o" },
            native_libraries = { backend = "gnu", dependency_file = root .. "/link.d" } }
    end)
    after_each(function() remove(root) end)

    it("reuses unchanged inputs, libraries and final outputs without reading their bytes", function()
        seed()
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, spec)
        assert.is_true(certificate.check(ctx, ticket))
        for _, leaf in ipairs(bulk) do
            assert.equal(0, ctx.io.reads[root .. "/" .. leaf] or 0, leaf)
        end
        local record = assert(certificate.read_record(ctx, ticket.record))
        assert.is_nil(record.observation)
        assert.is_nil(record.native[1].observation)
        assert.is_nil(record.outputs[1].observation)
        saved(ctx)
    end)

    it("rereads a changed ctime with fixed inode, mtime and size without making observations semantic", function()
        seed()
        local filename = root .. "/provider.so"
        local editor = model:context()
        local before = assert(editor.io:stat(filename))
        assert(editor.io:write_file(filename, "provider.so bytes"))
        local after = assert(editor.io:stat(filename))
        assert.equal(before.ino, after.ino)
        assert.equal(before.mtime_ns, after.mtime_ns)
        assert.equal(before.size, after.size)
        assert.not_equal(before.ctime_ns, after.ctime_ns)
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, spec)
        assert.is_true(certificate.check(ctx, ticket))
        assert.is_true((ctx.io.reads[filename] or 0) > 0)
        assert.equal(0, ctx.io.reads[root .. "/main.o"] or 0)
        saved(ctx)
        assert(editor.io:write_file(filename, string.rep("X", #"provider.so bytes")))
        ctx = model:context()
        ticket = certificate.prepare(ctx, spec)
        assert.is_false(certificate.check(ctx, ticket))
        assert.is_true((ctx.io.reads[filename] or 0) > 0)
    end)

    it("rereads a same-size changed final output when only its ctime changes", function()
        seed()
        local filename = root .. "/program"
        local editor = model:context()
        assert(editor.io:write_file(filename, string.rep("X", #"program bytes")))
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, spec)
        local hit, reason = certificate.check(ctx, ticket)
        assert.is_false(hit)
        assert.equal("link outputs changed", reason)
        assert.is_true((ctx.io.reads[filename] or 0) > 0)
        assert.equal(0, ctx.io.reads[root .. "/main.o"] or 0)
    end)

    it("keeps fresh post-link rehashing even with a warm persistent cache", function()
        seed()
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, spec)
        assert.equal(0, ctx.io.reads[root .. "/main.o"] or 0)
        assert(certificate.commit(ctx, ticket))
        for _, leaf in ipairs(bulk) do
            assert.is_true((ctx.io.reads[root .. "/" .. leaf] or 0) > 0, leaf)
        end
        saved(ctx)
        local next_context = model:context()
        assert.is_true(certificate.check(next_context, certificate.prepare(next_context, spec)))
        assert.equal(0, next_context.io.reads[root .. "/program"] or 0)
    end)

    it("falls back to reads with coarse observations", function()
        seed()
        model.coarse = true
        local ctx = model:context()
        assert.is_true(certificate.check(ctx, certificate.prepare(ctx, spec)))
        for _, leaf in ipairs(bulk) do
            assert.is_true((ctx.io.reads[root .. "/" .. leaf] or 0) > 0, leaf)
        end
    end)

    it("uses the precise cache for native source, dependency and committed object bytes", function()
        local native = require "titan-compiler.nativeinputs"
        local source, header = root .. "/helper.c", root .. "/helper.h"
        local contents = { [source] = "int helper(void);", [header] = "#define VALUE 1" }
        write(source, contents[source]); write(header, contents[header])
        local function compile(ctx)
            local phases = {}
            local objects, err = native.compile(ctx, {
                sources = { source }, output_root = root, compile_argv = { "fake-cc" },
                toolchain = "toolchain", incremental = true,
                run = function(argv, phase)
                    phases[#phases + 1] = phase
                    local output, dependencies
                    for index, argument in ipairs(argv) do
                        if argument == "-o" then output = argv[index + 1]
                        elseif argument == "-MF" then dependencies = argv[index + 1] end
                    end
                    local expanded = contents[source] .. "\n" .. contents[header]
                    assert(ctx.io:write_file(output, (phase == "native-compile" and "object:" or "expanded:") .. expanded))
                    if dependencies then
                        assert(ctx.io:write_file(dependencies,
                            "titan-native: " .. escape(source) .. " " .. escape(header) .. "\n"))
                    end
                    return { started = true, ok = true }
                end,
            })
            assert.truthy(objects, err)
            saved(ctx)
            return objects[1], phases
        end
        local first = compile(model:context())
        local warm = model:context()
        local second, phases = compile(warm)
        assert.is_true(second.hit)
        assert.same({ "native-preprocess" }, phases)
        for _, path in ipairs({ source, header, first.path }) do
            assert.equal(0, warm.io.reads[path] or 0, path)
        end
        local editor = model:context()
        contents[header] = "#define VALUE 2"
        assert(editor.io:write_file(header, contents[header]))
        local changed = model:context()
        local third = compile(changed)
        assert.is_false(third.hit)
        assert.is_true((changed.io.reads[header] or 0) > 0)
        assert.not_equal(first.identity, third.identity)
        contents[source] = "int sample(void);"
        assert(editor.io:write_file(source, contents[source]))
        local source_changed = model:context()
        local fourth = compile(source_changed)
        assert.is_false(fourth.hit)
        assert.is_true((source_changed.io.reads[source] or 0) > 0)
        local object_size = assert(editor.io:stat(fourth.path)).size
        assert(editor.io:write_file(fourth.path, string.rep("Z", object_size)))
        local object_changed = model:context()
        local repaired = compile(object_changed)
        assert.is_false(repaired.hit)
        assert.is_true((object_changed.io.reads[fourth.path] or 0) > 0)
        assert.equal(fourth.identity, repaired.identity)
    end)
end)

describe("linker dependency-feature memo", function()
    local root, model, request, probes, resolves, reports, banner, supported, signal
    local function invocation()
        local ctx = model:context()
        function ctx.io:run(argv)
            local named = argv[#argv]:match("^%-print%-prog%-name=(.+)$")
            if named then
                resolves = resolves + 1
                return { started = true, ok = true, output = root .. "/" .. named .. "\n" }
            end
            probes = probes + 1
            for _, argument in ipairs(argv) do
                local path = argument:match("^%-Wl,%-%-dependency%-file=(.+)$")
                if path then reports[#reports + 1] = path end
            end
            if signal then error(signal, 0) end
            return { started = true, ok = supported, why = "exit", status = supported and 0 or 1, output = banner }
        end
        return ctx
    end
    local function detect(overrides)
        local ctx, options = invocation(), clone(request)
        for key, value in pairs(overrides or {}) do options[key] = value end
        local backend, err = certificate.linker_backend(ctx, options)
        assert.truthy(backend, err)
        assert(incremental.save_digest_cache(ctx))
        return backend, ctx
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        model = precise_model(root)
        for _, tool in ipairs({ "cc", "ld", "ld.lld" }) do
            write(root .. "/" .. tool, "tool")
            model.executables[root .. "/" .. tool] = true
        end
        request = { compiler_argv = { root .. "/cc" }, toolchain = "toolchain", directory = root }
        probes, resolves, reports, banner, supported, signal = 0, 0, {}, "GNU ld 2.45", true, nil
    end)
    after_each(function()
        for _, path in ipairs(reports) do assert.is_nil(lfs.symlinkattributes(path), path) end
        remove(root)
    end)

    it("reuses feature detection while re-resolving the physical linker", function()
        assert.equal("gnu", detect())
        local filename = root .. "/.titan/linker-feature"
        local old = os.time() - 60
        assert(lfs.touch(filename, old, old))
        assert.equal("gnu", detect())
        assert.equal(1, probes)
        assert.equal(2, resolves)
        assert.equal(old, lfs.attributes(filename, "modification"))
    end)

    it("invalidates feature detection for same-path linker replacement and changed flags", function()
        assert.equal("gnu", detect())
        local editor = model:context()
        assert(editor.io:write_file(root .. "/ld", "edit"))
        banner = "LLD 22.1"
        assert.equal("lld", detect())
        assert.equal(2, probes)
        assert.equal("lld", detect({ link_flags = { "-fuse-ld=lld" } }))
        assert.equal(3, probes)
        assert.equal("lld", detect({ link_flags = { "--ld-path=" .. root .. "/ld", "-fuse-ld=lld" } }))
        assert.equal(4, probes)
    end)

    it("memoizes unsupported dependency output and reprobes malformed memo data", function()
        supported = false
        assert.equal("none", detect())
        assert.equal("none", detect())
        assert.equal(1, probes)
        local editor = model:context()
        assert(editor.io:write_file(root .. "/.titan/linker-feature", "not a data record"))
        supported = true
        assert.equal("gnu", detect())
        assert.equal(2, probes)
    end)

    it("cleans the report and preserves cancellation without caching a verdict", function()
        signal = {}
        local ctx = invocation()
        local ok, err = pcall(certificate.linker_backend, ctx, request)
        assert.is_false(ok)
        assert.equal(signal, err)
        assert.is_nil(lfs.symlinkattributes(root .. "/.titan/linker-feature"))
    end)

    it("does not probe fixed Darwin and Windows policies", function()
        assert.equal("darwin", certificate.linker_backend({}, { darwin = true }))
        assert.equal("none", certificate.linker_backend({}, { windows = true }))
        assert.equal(0, probes)
    end)
end)

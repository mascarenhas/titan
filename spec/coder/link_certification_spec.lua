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
local function native_spelling(path)
    return platform.windows and assert(platform.path.normalize(path)) or path
end
local function observation_key(path)
    return platform.windows and path:gsub("\\", "/") or path
end

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
    function model:context()
        local strategy = compiler_io.new_sync()
        local stat, lstat, read_file = strategy.stat, strategy.lstat, strategy.read_file
        local write_file, rename = strategy.write_file, strategy.rename
        strategy.reads = {}
        local function decorate(metadata, err, path)
            if not metadata then return nil, err end
            path = observation_key(path)
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
        function strategy:executable(path)
            return model.executables[observation_key(path)] == true
        end
        function strategy:executable_search_cwd()
            return model.search_cwd ~= false
        end
        function strategy:read_file(path, bound)
            local name = observation_key(path)
            self.reads[name] = (self.reads[name] or 0) + 1
            return read_file(self, path, bound)
        end
        local function changed(path)
            model.clock = model.clock + 1
            model.ctime[observation_key(path)] = model.clock
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
            assert.same({ native_spelling(directory .. "/A"), native_spelling(directory .. "/z"),
                native_spelling(directory .. "/é") }, names)
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
    local function compile(arguments, expected, environment)
        local argv = { platform.windows and "env.exe" or "env", "TITAN_RUNTIME_PREBUILT=1",
            "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_ROCKS_ROOT=" .. prefix, "TITAN_EXTRA_CPPFLAGS=",
            "TITAN_EXTRA_CFLAGS=-O0 -fno-lto", "TITAN_EXTRA_LDFLAGS=-fno-lto" }
        for name, value in pairs(environment or {}) do argv[#argv + 1] = name .. "=" .. value end
        for _, value in ipairs({ lua, "-E", frontend, "--incremental",
            "--tree", root, "--output", root .. "/out" }) do argv[#argv + 1] = value end
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
        local function companion_snapshot(executable)
            local ctx = context()
            local paths = assert(require("titan-compiler.driver").windows_program_paths(
                "checks", executable, nil, root .. "/out"))
            local target = certificate.canonical_path(ctx, paths.executable)
            local provider = certificate.canonical_path(ctx, paths.provider)
            local directory = root .. "/out/.titan-links"
            for key in lfs.dir(directory) do
                if key ~= "." and key ~= ".." then
                    local record = certificate.read_record(ctx, directory .. "/" .. key .. "/record")
                    if record then
                        local owns_target, companion
                        for _, output in ipairs(record.outputs) do
                            if output.path == target then owns_target = true end
                            if output.path == provider then companion = output end
                        end
                        if owns_target then return assert(companion, "missing provider snapshot") end
                    end
                end
            end
            error("missing final output record for " .. executable)
        end
        local first_companion = platform.windows and companion_snapshot(exe("tests-one"))
        local companion_changed = false
        compile({ "--test", "--exe", exe("tests-two"), "checks" })
        assert.matches("render", read(log), 1, true)
        if first_companion then
            local second_companion = companion_snapshot(exe("tests-two"))
            assert.equal(first_companion.path, second_companion.path)
            companion_changed = first_companion.identity ~= second_companion.identity
        end
        write(log, "")
        compile({ "--test", "--exe", exe("tests-one"), "checks" })
        if companion_changed then assert.matches("render", read(log), 1, true)
        else assert.equal("", read(log)) end
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

    for _, spelling in ipairs({ "CLI", "environment", "Windows -l archive", "Windows -l import",
        "Windows -l static", "POSIX -L traversal" }) do
        local raw = spelling == "CLI" or spelling == "environment"
        local label = raw and ("raw " .. spelling) or spelling
        it("relinks unchanged objects after a preserved-mtime " .. label .. " native archive replacement", function()
            local traversed = spelling == "POSIX -L traversal"
            if not raw and not traversed and not platform.windows then pending("Windows MinGW library selection"); return end
            if traversed and platform.windows then pending("POSIX symlink-directory traversal"); return end
            local cdriver = require "c-parser.cdriver"
            local driver = require "titan-compiler.driver"
            local cc = assert(cdriver.split_shell_words(driver.CC))
            if cc[1] == "exec" then table.remove(cc, 1) end
            local function run(argv)
                local result = context().io:run(argv)
                assert.is_true(result.started and result.ok, result.output or result.diagnostic)
            end
            local selected = root .. "/selected vendor Ω" .. (platform.windows and ".dll.a" or ".a")
            local native_directory, later_directory, competitor
            if traversed then
                local route, physical = root .. "/lexical route", root .. "/physical target"
                for _, directory in ipairs({ route, physical, route .. "/lib", physical .. "/inner", physical .. "/lib" }) do
                    assert(lfs.mkdir(directory))
                end
                assert(lfs.link(physical .. "/inner", route .. "/link", true))
                native_directory = route .. "/link/../lib"
                selected, competitor = physical .. "/lib/libhelper.a", route .. "/lib/libhelper.a"
            elseif not raw then
                native_directory = root .. "/native vendor Ω"
                assert(lfs.mkdir(native_directory))
                if spelling == "Windows -l archive" then
                    selected, competitor = native_directory .. "/libhelper.a", native_directory .. "/helper.lib"
                elseif spelling == "Windows -l import" then
                    selected, competitor = native_directory .. "/helper.dll.a", native_directory .. "/libhelper.a"
                else
                    later_directory = root .. "/later vendor"
                    assert(lfs.mkdir(later_directory))
                    selected, competitor = native_directory .. "/helper.lib", later_directory .. "/libhelper.a"
                end
            end
            local environment = {}
            if platform.windows then
                -- Exercise the real default Windows fallback, not an injected
                -- capability. Each import archive names a different live DLL.
                environment.CC = driver.CC
                environment.PATH = root .. ";" .. (platform.getenv("PATH") or "")
            elseif driver.IS_DARWIN then
                -- Darwin always has dependency_info. Select the fallback policy
                -- for this fixture while keeping all compilation/linking real.
                local source = read(frontend)
                source = source:gsub("\ndofile%(",
                    "\ndriver.native_link_backend = function() return 'none' end\ndofile(", 1)
                write(frontend, source)
            else
                local quoted = {}
                for _, word in ipairs(cc) do quoted[#quoted + 1] = assert(cdriver.shell_quote(word)) end
                local wrapper = root .. "/unsupported-dependency-linker.sh"
                write(wrapper, "#!/bin/sh\nfor argument do\ncase \"$argument\" in\n" ..
                    "-Wl,--dependency-file=*) exit 1;;\nesac\ndone\nexec " ..
                    table.concat(quoted, " ") .. " \"$@\"\n")
                run({ "chmod", "+x", wrapper })
                environment.CC = assert(cdriver.shell_quote(wrapper))
            end
            local function build(label, value)
                local source, archive = root .. "/helper.c", root .. "/vendor-" .. label .. ".a"
                write(source, "#ifdef _WIN32\n__declspec(dllexport)\n#endif\n" ..
                    "int helper(void) { return " .. value .. "; }\n")
                local argv = { table.unpack(cc) }
                for _, flag in ipairs({ "-O0", "-fno-lto", "-fPIC" }) do argv[#argv + 1] = flag end
                if platform.windows then
                    for _, flag in ipairs({ "-shared", source, "-Wl,--out-implib=" .. archive,
                        "-o", root .. "/vendor-" .. label .. ".dll" }) do argv[#argv + 1] = flag end
                    run(argv)
                else
                    local object = root .. "/helper.o"
                    for _, flag in ipairs({ "-c", source, "-o", object }) do argv[#argv + 1] = flag end
                    run(argv)
                    local ar = assert(cdriver.split_shell_words(driver.AR or "ar"))
                    for _, flag in ipairs({ "rcs", archive, object }) do ar[#ar + 1] = flag end
                    run(ar)
                end
                return read(archive)
            end
            local first, second = build("one", 17), build("two", 29)
            assert.not_equal(first, second)
            if competitor then write(competitor, second) end
            write(selected, first)
            local old = os.time() - 60
            assert(lfs.touch(selected, old, old))
            write(root .. "/helper.h", "int helper(void);\n")
            write(root .. "/app.titan", 'foreign import "helper.h"\nfunction main(args: {string}): integer return ffi.helper() as integer end\n')
            local program = exe("raw-input")
            local arguments = { "--exe", program }
            if not raw then
                arguments[#arguments + 1] = "-L" .. native_directory
                if later_directory then arguments[#arguments + 1] = "-L" .. later_directory end
                if spelling == "Windows -l static" then arguments[#arguments + 1] = "--ldflag=-Wl,-Bstatic" end
                arguments[#arguments + 1] = "-lhelper"
            elseif spelling == "CLI" then arguments[#arguments + 1] = "--ldflag=" .. selected
            else environment.TITAN_EXTRA_LDFLAGS = "-fno-lto " .. assert(cdriver.shell_quote(selected)) end
            arguments[#arguments + 1] = "app"
            compile(arguments, nil, environment)
            assert.equal(17, context().io:run({ program }).status)
            local object = root .. "/out/app.o"
            local object_bytes = read(object)
            assert(lfs.touch(object, old, old))
            write(log, "")
            compile(arguments, nil, environment)
            assert.equal("", read(log))
            assert.equal(old, lfs.attributes(object, "modification"))
            if traversed then
                local competitor_time = assert(lfs.attributes(competitor)).modification
                write(competitor, first)
                assert(lfs.touch(competitor, competitor_time, competitor_time))
                compile(arguments, nil, environment)
                assert.equal("", read(log))
                assert.equal(old, lfs.attributes(object, "modification"))
                assert.equal(object_bytes, read(object))
                assert.equal(17, context().io:run({ program }).status)
            end
            write(selected, second)
            assert(lfs.touch(selected, old, old))
            compile(arguments, nil, environment)
            assert.matches("compile_program", read(log), 1, true)
            assert.equal(old, lfs.attributes(selected, "modification"))
            assert.equal(old, lfs.attributes(object, "modification"))
            assert.equal(object_bytes, read(object))
            assert.equal(29, context().io:run({ program }).status)
            write(log, "")
            compile(arguments, nil, environment)
            assert.equal("", read(log))
        end)
    end

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
        root = certificate.canonical_path(context(), root)
        write(root .. "/libfirst.a", "!<arch>\n")
        write(root .. "/libsecond.a", "!<arch>\n")
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
        assert.same(platform.windows and {
            "-print-file-name=libfirst.dll.a", "-print-file-name=first.dll.a", "-print-file-name=libfirst.a",
            "-print-file-name=first.lib", "-print-file-name=libfirst.dll", "-print-file-name=first.dll",
        } or { "-print-file-name=libfirst.so", "-print-file-name=libfirst.a" }, calls)
    end)

    it("retains static and dynamic library selection in ordered fallback arguments", function()
        local policy = certificate.native_library_policy(context(), {
            compiler_argv = { "selected-cc" }, argv = {
                "-L" .. root, "-Wl,-Bstatic", "-lfirst", "-Wl,-Bdynamic", "-lsecond", "-lfirst",
            },
        })
        assert.is_true(policy.cacheable)
        assert.same({ native_spelling(root .. "/libfirst.a"), native_spelling(root .. "/libsecond.a"),
            native_spelling(root .. "/libfirst.a") }, policy.files)
    end)

    it("retains POSIX library-search traversal when a lexical competitor already exists", function()
        if platform.windows then pending("POSIX symlink-directory traversal"); return end
        local route, physical = root .. "/route", root .. "/physical"
        for _, directory in ipairs({ route, physical, route .. "/lib", physical .. "/inner", physical .. "/lib" }) do
            assert(lfs.mkdir(directory))
        end
        assert(lfs.link(physical .. "/inner", route .. "/link", true))
        write(route .. "/lib/libfirst.a", "!<arch>\n")
        write(physical .. "/lib/libfirst.a", "!<arch>\n")
        local directory = route .. "/link/../lib"
        local ctx = context()
        function ctx.io:run() error("existing explicit library must not require compiler lookup") end
        local policy = certificate.native_library_policy(ctx, {
            backend = "none", compiler_argv = { "selected-cc" }, argv = { "-L", directory, "-lfirst" },
        })
        assert.is_true(policy.cacheable, policy.reason)
        assert.same({ directory .. "/libfirst.a" }, policy.files)
        assert.equal(ctx.io:realpath(physical .. "/lib/libfirst.a"), ctx.io:realpath(policy.files[1]))
        assert.not_equal(ctx.io:realpath(route .. "/lib/libfirst.a"), ctx.io:realpath(policy.files[1]))
    end)

    for _, case in ipairs({
        { name = "prefixed import archive", selected = "one/libchoice.dll.a",
            files = { "one/libchoice.dll.a", "one/choice.dll.a", "one/libchoice.a", "one/choice.lib" } },
        { name = "unprefixed import archive", selected = "one/choice.dll.a",
            files = { "one/choice.dll.a", "one/libchoice.a", "one/choice.lib" } },
        { name = "native archive before .lib", selected = "one/libchoice.a",
            files = { "one/libchoice.a", "one/choice.lib" } },
        { name = "DLL candidate", selected = "one/libchoice.dll",
            files = { "one/libchoice.dll", "one/choice.dll" } },
        { name = "static .lib in an earlier directory", selected = "one/choice.lib", static = true,
            files = { "one/choice.lib", "two/libchoice.a" } },
    }) do
        it("tracks the existing MinGW " .. case.name .. " and invalidates only the changed selected input", function()
            assert(lfs.mkdir(root .. "/one")); assert(lfs.mkdir(root .. "/two"))
            local function image(value, dll)
                if dll then
                    return "MZ" .. string.rep("\0", 58) .. string.pack("<I4", 64) .. "PE\0\0" ..
                        string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, value, 0, 0, 0, 0x2000)
                end
                local member = string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, value, 0, 0, 0, 0)
                return "!<arch>\n" .. string.format("%-16s%-12d%-6d%-6d%-8s%-10d`\n",
                    "helper.o/", 0, 0, 0, "100644", #member) .. member
            end
            for _, path in ipairs(case.files) do write(root .. "/" .. path, image(1, path:match("%.dll$"))) end
            local selected, object = root .. "/" .. case.selected, root .. "/main.o"
            local object_bytes = string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0)
            write(object, object_bytes); write(root .. "/program", "image")
            local old = os.time() - 60
            assert(lfs.touch(selected, old, old)); assert(lfs.touch(object, old, old))
            local model = precise_model(root)
            local argv = { "-L" .. root .. "/one", "-L" .. root .. "/two" }
            if case.static then argv[#argv + 1] = "-Wl,-Bstatic" end
            argv[#argv + 1] = "-lchoice"
            local function prepare()
                local ctx = model:context()
                function ctx.io:run() error("explicit selected library must not require compiler lookup") end
                return ctx, certificate.prepare(ctx, {
                    output_root = root, outputs = { root .. "/program" }, objects = { object },
                    roots = { "app" }, kind = "program", toolchain = "compiler", argv = argv,
                    native_libraries = { backend = "none", compiler_argv = { "selected-cc" }, windows = true },
                })
            end
            local ctx, ticket = prepare()
            assert.same({ native_spelling(selected) }, ticket.native_policy.files)
            assert(certificate.commit(ctx, ticket))
            assert(incremental.save_digest_cache(ctx))
            ctx, ticket = prepare()
            assert.is_true(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[object])
            assert(model:context().io:write_file(selected, image(2, case.selected:match("%.dll$"))))
            assert(lfs.touch(selected, old, old))
            ctx, ticket = prepare()
            assert.same({ native_spelling(selected) }, ticket.native_policy.files)
            assert.is_false(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[object])
            assert.equal(old, lfs.attributes(selected, "modification"))
            assert.equal(old, lfs.attributes(object, "modification"))
            assert.equal(object_bytes, assert(context().io:read_file(object)))
        end)
    end

    it("declines ambiguous implicit compiler directories instead of choosing by filename priority", function()
        assert(lfs.mkdir(root .. "/one")); assert(lfs.mkdir(root .. "/two"))
        write(root .. "/one/choice.lib", "!<arch>\n")
        write(root .. "/two/libchoice.a", "!<arch>\n")
        local ctx = context()
        function ctx.io:run(argv)
            local name = argv[#argv]:match("=(.+)$")
            local path = name == "choice.lib" and root .. "/one/choice.lib"
                or name == "libchoice.a" and root .. "/two/libchoice.a" or name
            return { started = true, ok = true, output = path .. "\n" }
        end
        for _, argv in ipairs({ { "-lchoice" }, { "-Wl,-Bstatic", "-lchoice" } }) do
            local policy = certificate.native_library_policy(ctx, {
                backend = "none", compiler_argv = { "selected-cc" }, windows = true, argv = argv,
            })
            assert.is_false(policy.cacheable)
            assert.matches("ambiguous compiler library search order", policy.reason, 1, true)
        end
    end)

    it("retains raw archive object and import-library operands in their original order", function()
        local object = root .. "/helper.o"
        write(object, string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0))
        write(root .. "/vendor.dll.a", "!<arch>\n")
        write(root .. "/vendor.lib", "!<arch>\n")
        local files = { root .. "/vendor.dll.a", object, root .. "/vendor.lib", object }
        local policy = certificate.native_library_policy(context(), {
            compiler_argv = { "selected-cc" }, argv = {
                files[1], "-L" .. root, "-lfirst", files[2], "-Wl,--whole-archive",
                files[3], "-Wl,--no-whole-archive", files[4], "-O0", "-fno-lto",
            },
        })
        assert.is_true(policy.cacheable, policy.reason)
        assert.same({ files[1], native_spelling(root .. "/libfirst.a"), files[2], files[3], files[4] }, policy.files)
    end)

    it("tracks direct file-taking switches without interpreting symbol files as native objects", function()
        local symbols = root .. "/symbols"
        write(symbols, "helper\n")
        local policy = certificate.native_library_policy(context(), {
            compiler_argv = { "selected-cc" },
            argv = { "-Wl,--retain-symbols-file," .. symbols, "-Wl,--just-symbols=" .. root .. "/libfirst.a" },
        })
        assert.is_true(policy.cacheable, policy.reason)
        assert.same({ symbols, root .. "/libfirst.a" }, policy.files)
    end)

    it("does not certify thin archives scripts or unknown file mechanisms as an empty set", function()
        write(root .. "/thin.a", "!<thin>\n")
        write(root .. "/script.so", "INPUT(other.a)\n")
        for _, argv in ipairs({
            { root .. "/thin.a" }, { root .. "/script.so" }, { "--unrecognized-files=hidden" },
            { "-Wl,-T," .. root .. "/script.so" }, { "-Wl,--retain-symbols-file" },
        }) do
            local policy = certificate.native_library_policy(context(), {
                compiler_argv = { "selected-cc" }, argv = argv,
            })
            assert.is_false(policy.cacheable)
            assert.is_string(policy.reason)
        end
    end)

    it("makes unsupported response and plugin mechanisms explicitly uncacheable", function()
        for _, flag in ipairs({ "@response", "-Wl,@response", "-Wl,-plugin,plugin.so",
            "-Wl,--plugin,plugin.so", "-Wl,-filelist,objects.list" }) do
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
        assert.is_true((object_changed.io.reads[observation_key(fourth.path)] or 0) > 0)
        assert.equal(fourth.identity, repaired.identity)
    end)
end)

describe("linker dependency-feature memo", function()
    local root, model, request, probes, resolves, reports, banner, supported, signal, description, descriptions, previous_cwd
    local description_result, stage_paths
    local function invocation()
        local ctx = model:context()
        function ctx.io:run(argv)
            for _, argument in ipairs(argv) do
                if argument == "-###" then
                    descriptions = descriptions + 1
                    return description_result or { started = true, ok = true, output = description }
                end
            end
            local named = argv[#argv]:match("^%-print%-prog%-name=(.+)$")
            if named then
                resolves = resolves + 1
                return { started = true, ok = true, output = (stage_paths[named] or root .. "/" .. named) .. "\n" }
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
    local function final_ticket(overrides, search)
        local ctx, options = invocation(), clone(request)
        ctx.executable_path = search
        for key, value in pairs(overrides or {}) do options[key] = value end
        options.inputs = options.inputs or { root .. "/main.o" }
        local tools, err = certificate.output_tools(ctx, options)
        assert.truthy(tools, err)
        local ticket = certificate.prepare(ctx, {
            output_root = root, outputs = { root .. "/program" }, roots = { "app" }, kind = "program",
            objects = { root .. "/main.o" }, argv = options.link_flags or {},
            toolchain = { compiler = options.toolchain, output_tools = tools },
            native_libraries = { backend = "none", compiler_argv = options.compiler_argv },
        })
        return ctx, ticket, tools
    end
    local function seed_final(overrides, search)
        local ctx, ticket = final_ticket(overrides, search)
        assert(certificate.commit(ctx, ticket))
        assert(incremental.save_digest_cache(ctx))
    end

    local function windows_lookup(command, expected, search, selection, search_cwd)
        local ctx, metadata = model:context(), {}
        ctx.executable_path = search
        function ctx.io:executable_search_cwd() return search_cwd ~= false end
        local function normalized(path)
            return assert(platform.path.normalize(assert(platform.absolute(path, assert(ctx.io:cwd()))))):lower()
        end
        for _, method in ipairs({ "stat", "lstat" }) do
            local observe = ctx.io[method]
            ctx.io[method] = function(self, path)
                local value, err = observe(self, path)
                if value then metadata[normalized(path)] = value end
                return value, err
            end
        end
        function ctx.io:readable() error("Windows executable lookup must not test readability") end
        function ctx.io:executable() error("Windows executable lookup must not test POSIX execution access") end
        function ctx.io:read_file() error("physical executable identity must not read tool bytes") end
        function ctx.io:run() error("physical executable identity must not run native commands") end
        local ok, identity, admitted = pcall(incremental.physical_executable, ctx, command, selection)
        if not expected then
            assert.is_false(ok)
            assert.is_string(identity)
            return
        end
        assert.is_true(ok, identity)
        assert.truthy(identity, admitted)
        assert.is_true(platform.is_absolute(admitted))
        assert.equal(normalized(expected), normalized(admitted))
        assert.equal(expected:match("[^/\\]+$"), admitted:match("[^/\\]+$"))
        assert.equal(normalized(assert(ctx.io:realpath(expected))), normalized(identity.path))
        local selected_stat = assert(metadata[normalized(expected)])
        for _, field in ipairs({ "size", "mode", "dev", "ino", "mtime_ns", "ctime_ns" }) do
            assert.equal(selected_stat[field], identity[field], field)
        end
    end

    before_each(function()
        previous_cwd = assert(lfs.currentdir())
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        root = certificate.canonical_path(context(), root)
        assert(lfs.chdir(root))
        model = precise_model(root)
        for _, tool in ipairs({ "cc", "ld", "ld.lld", "collect2", "lto-wrapper", "lto1" }) do
            write(root .. "/" .. tool, "tool")
            model.executables[root .. "/" .. tool] = true
        end
        if platform.windows then write(root .. "/cc.exe", "tool") end
        write(root .. "/liblto_plugin.so", "tool")
        write(root .. "/libLTO.dylib", "tool")
        write(root .. "/main.o", string.pack("<I2I2I4I4I4I2I2", 0x8664, 0, 0, 0, 0, 0, 0))
        write(root .. "/program", "image")
        description = ' "' .. root .. '/collect2"\n'
        descriptions = 0
        request = { compiler_argv = { root .. "/cc" }, toolchain = "toolchain", directory = root,
            compiler_stage_policy = "llvm" }
        description_result, stage_paths = nil, {}
        probes, resolves, reports, banner, supported, signal = 0, 0, {}, "GNU ld 2.45", true, nil
    end)
    after_each(function()
        assert(lfs.chdir(previous_cwd))
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

    it("identifies GNU ld independently of echoed probe paths", function()
        local directory = root .. "/permission build"
        assert(lfs.mkdir(directory))
        local object = directory .. "/permission_library.o"
        write(object, "reported object")
        banner = "collect2 version 16.1.1\n " .. root ..
            "/ld --dependency-file=" .. root .. "/lua_LLDr7x --version\nGNU ld 2.45\n"
        local backend = detect()
        assert.equal("gnu", backend)
        assert.equal("gnu", detect())
        assert.equal(1, probes)
        local report = root .. "/link.d"
        write(report, gnu_report(root .. "/program", { object }))
        local ctx = model:context()
        local ticket = certificate.prepare(ctx, {
            output_root = root, outputs = { root .. "/program" }, roots = { "app" },
            kind = "program", objects = { root .. "/main.o" }, toolchain = "toolchain",
            native_libraries = { backend = backend, dependency_file = report },
        })
        assert(certificate.commit(ctx, ticket))
        local record = assert(certificate.read_record(ctx, ticket.record))
        assert.equal(1, #record.native)
        assert.equal(native_spelling(object), record.native[1].path)
        assert.is_true(certificate.check(model:context(), ticket))
        write(object, "changed reported object")
        assert.is_false(certificate.check(model:context(), ticket))
    end)

    it("identifies vendor LLD version lines independently of echoed paths", function()
        banner = "collect2 version 16.1.1\n " .. root ..
            "/GNU ld/ld --version\nDebian LLD 22.1.8 (compatible with GNU linkers)\n"
        assert.equal("lld", detect())
        assert.equal("lld", detect())
        assert.equal(1, probes)
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

    it("resolves fixed Darwin and Windows linkers without dependency-feature probes", function()
        assert.equal("darwin", detect({ darwin = true }))
        assert.equal("none", detect({ windows = true }))
        assert.equal(0, probes)
        assert.equal(2, resolves)
    end)

    it("shares linker resolution between feature detection and final tool inventory", function()
        local ctx = invocation()
        assert.equal("gnu", certificate.linker_backend(ctx, request))
        local tools = assert(certificate.output_tools(ctx, request))
        assert.equal(native_spelling(root .. "/ld"), tools.linker.identity.path)
        assert.equal(1, probes)
        assert.equal(1, resolves)
        assert.equal(1, descriptions)
        assert.is_nil(tools.lto_compiler)
        assert.equal(native_spelling(root .. "/collect2"), tools.link_driver.identity.path)
    end)

    for _, fixed in ipairs({ "native", "darwin", "windows" }) do
        it("invalidates the final certificate for a same-backend " .. fixed .. " linker replacement", function()
            local options = { darwin = fixed == "darwin", windows = fixed == "windows" }
            seed_final(options)
            local ctx, ticket = final_ticket(options)
            assert.is_true(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert(model:context().io:write_file(root .. "/ld", "edit"))
            ctx, ticket = final_ticket(options)
            assert.is_false(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert.equal("GNU ld 2.45", banner)
        end)
    end

    it("uses the compiler-described default linker rather than a same-name PATH guess", function()
        description = ' "' .. root .. '/ld.lld" "-o" "/dev/null"\n'
        local ctx, ticket, tools = final_ticket({ windows = true })
        assert.equal(native_spelling(root .. "/ld.lld"), tools.linker.identity.path)
        assert.equal(0, resolves)
        assert(certificate.commit(ctx, ticket))
        assert(incremental.save_digest_cache(ctx))
        assert(model:context().io:write_file(root .. "/ld.lld", "edit"))
        ctx, ticket = final_ticket({ windows = true })
        assert.is_false(certificate.check(ctx, ticket))
        assert.is_nil(ctx.io.reads[root .. "/main.o"])
    end)

    for _, location in ipairs({ "absolute", "relative", "PATH" }) do
        for _, dotted in ipairs({ false, true }) do
            local kind = dotted and "dotted" or "undotted"
            it("admits the Windows .exe file for an " .. location .. " " .. kind .. " tool spelling", function()
                if not platform.windows then pending("Windows executable suffix selection"); return end
                local directory = root .. "/Windows tools"
                assert(lfs.mkdir(directory))
                local name = dotted and "compiler.stage" or "compiler-stage"
                local requested, selected = directory .. "/" .. name, directory .. "/" .. name .. ".exe"
                write(selected, "tool")
                local search
                if location ~= "absolute" then
                    assert(lfs.chdir(root))
                    if location == "relative" then requested = "Windows tools\\" .. name
                    else requested, search = name, "Windows tools" end
                end
                windows_lookup(requested, selected, search)
            end)
        end
    end

    it("keeps Windows exact-first candidates grouped within each PATH directory", function()
        if not platform.windows then pending("Windows executable suffix selection"); return end
        local first, later = root .. "/first tools", root .. "/later tools"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(later))
        local name = "compiler.stage"
        write(first .. "/" .. name .. ".exe", "tool")
        write(later .. "/" .. name, "tool")
        local search = first .. ";" .. later
        windows_lookup(name, first .. "/" .. name .. ".exe", search)
        write(first .. "/" .. name, "tool")
        windows_lookup(name, first .. "/" .. name, search)
    end)

    for _, extension in ipairs({ ".exe", ".EXE" }) do
        it("admits existing and appended Windows " .. extension .. " candidates under their execution policies", function()
            if not platform.windows then pending("Windows executable suffix selection"); return end
            local requested = root .. "/already" .. extension
            write(requested, "tool")
            write(requested .. ".com", "first")
            write(requested .. ".exe", "second")
            windows_lookup(requested, requested)
            windows_lookup(requested, requested, nil, "llvm")
            assert(os.remove(requested))
            windows_lookup(requested, requested .. ".com")
            windows_lookup(requested, requested .. ".exe", nil, "llvm")
            assert(os.remove(requested .. ".com"))
            windows_lookup(requested, requested .. ".exe")
        end)
    end

    it("admits a double-suffixed Windows PATH file before a later exact spelling", function()
        if not platform.windows then pending("Windows executable suffix selection"); return end
        local first, later = root .. "/first tools", root .. "/later tools"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(later))
        write(first .. "/already.EXE.exe", "tool")
        write(later .. "/already.EXE", "later")
        windows_lookup("already.EXE", first .. "/already.EXE.exe", first .. ";" .. later)
    end)

    for _, case in ipairs({
        { name = "exact", requested = "compiler.stage", missing = "compiler.stage" },
        { name = ".com", requested = "compiler-stage", missing = "compiler-stage.com" },
        { name = "PATH", requested = "compiler.stage", missing = "compiler.stage", search = true },
        { name = "LLVM exact", requested = "compiler.stage", missing = "compiler.stage", selection = "llvm" },
    }) do
        it("does not certify past an existing Windows " .. case.name .. " entry with no followed metadata", function()
            if not platform.windows then pending("Windows non-following tool entry observation"); return end
            local first, later = root .. "/first tools", root .. "/later tools"
            assert(lfs.mkdir(first)); assert(lfs.mkdir(later))
            write(first .. "/" .. case.requested .. ".exe", "suffix")
            write(later .. "/" .. case.requested, "later")
            local ctx = model:context()
            ctx.executable_path = first .. ";" .. later
            function ctx.io:executable_search_cwd() return false end
            local lstat, missing = ctx.io.lstat, first .. "/" .. case.missing
            function ctx.io:lstat(path)
                if path:gsub("\\", "/"):lower() == missing:lower() then
                    return { kind = "symlink", windows_attributes = 0x400 }
                end
                return lstat(self, path)
            end
            local command = case.search and case.requested or first .. "/" .. case.requested
            local identity, reason, status = incremental.physical_executable(ctx, command, case.selection)
            assert.is_nil(identity)
            assert.is_string(reason)
            assert.equal("uncertified", status)
        end)
    end

    it("continues from absent Windows tool entries to a real suffix candidate", function()
        if not platform.windows then pending("Windows non-following tool entry observation"); return end
        local path = root .. "/absent.stage"
        write(path .. ".exe", "tool")
        windows_lookup(path, path .. ".exe")
        windows_lookup(path, path .. ".exe", nil, "llvm")
    end)

    it("preserves non-following Windows tool observation errors and cancellation", function()
        if not platform.windows then pending("Windows non-following tool entry observation"); return end
        for _, failure in ipairs({ "tool entry observation failed", {} }) do
            for _, thrown in ipairs({ false, true }) do
                local ctx = model:context()
                function ctx.io:lstat()
                    if thrown then error(failure, 0) end
                    return nil, failure
                end
                local ok, err = pcall(incremental.physical_executable, ctx, root .. "/absent.stage")
                assert.is_false(ok)
                if type(failure) == "string" then assert.matches(failure, err, 1, true)
                else assert.equal(failure, err) end
            end
        end
    end)

    it("keeps a followed Windows tool link and its admitted spelling", function()
        if not platform.windows then pending("Windows followed tool link observation"); return end
        local target, alias = root .. "/tool-target.exe", root .. "/tool-alias.stage"
        write(target, "tool")
        for _, mode in ipairs({ "direct", "llvm" }) do
            local ctx = model:context()
            local stat, lstat, realpath = ctx.io.stat, ctx.io.lstat, ctx.io.realpath
            local function is_alias(path) return path:gsub("\\", "/"):lower() == alias:lower() end
            function ctx.io:stat(path) return stat(self, is_alias(path) and target or path) end
            function ctx.io:lstat(path)
                if is_alias(path) then return { kind = "symlink", windows_attributes = 0x400 } end
                return lstat(self, path)
            end
            function ctx.io:realpath(path) return realpath(self, is_alias(path) and target or path) end
            local identity, admitted = incremental.physical_executable(ctx, alias, mode == "llvm" and "llvm" or nil)
            assert.equal(native_spelling(target), identity.path)
            assert.equal(native_spelling(alias), admitted)
        end
    end)

    for _, case in ipairs({
        { name = "file link with directory target", attributes = 0x400, directory = true },
        { name = "directory link with file target", attributes = 0x410 },
        { name = "missing link attributes" },
        { name = "noninteger link attributes", attributes = 1.5 },
        { name = "string link attributes", attributes = "1024" },
        { name = "negative link attributes", attributes = -1 },
        { name = "invalid Windows attribute sentinel", attributes = 0xffffffff },
        { name = "out-of-range link attributes", attributes = 0x100000000 },
        { name = "directory link with directory target", attributes = 0x410, directory = true, valid = true },
    }) do
        it("retains entry evidence for a Windows " .. case.name, function()
            if not platform.windows then pending("Windows tool entry attributes"); return end
            local target, alias = root .. "/entry-target", root .. "/entry-alias.stage"
            if case.directory then assert(lfs.mkdir(target)) else write(target, "target") end
            write(alias .. ".exe", "fallback")
            for _, mode in ipairs({ "direct", "llvm" }) do
                local ctx = model:context()
                local stat, lstat = ctx.io.stat, ctx.io.lstat
                local function is_alias(path) return path:gsub("\\", "/"):lower() == alias:lower() end
                function ctx.io:lstat(path)
                    if is_alias(path) then return { kind = "symlink", windows_attributes = case.attributes } end
                    return lstat(self, path)
                end
                function ctx.io:stat(path) return stat(self, is_alias(path) and target or path) end
                local ok, identity, reason, status = pcall(incremental.physical_executable, ctx, alias,
                    mode == "llvm" and "llvm" or nil)
                if not case.valid then
                    assert.is_true(ok, identity)
                    assert.is_nil(identity)
                    assert.is_string(reason)
                    assert.equal("uncertified", status)
                elseif mode == "llvm" then
                    assert.is_false(ok)
                    assert.is_string(identity)
                else
                    assert.is_true(ok, identity)
                    assert.equal(native_spelling(alias .. ".exe"), identity.path)
                    assert.equal(native_spelling(alias .. ".exe"), reason)
                end
            end
        end)
    end

    it("preserves followed Windows tool observation errors and cancellation", function()
        if not platform.windows then pending("Windows followed tool observation"); return end
        for _, failure in ipairs({ "tool target observation failed", {} }) do
            for _, thrown in ipairs({ false, true }) do
                local ctx = model:context()
                function ctx.io:lstat() return { kind = "symlink", windows_attributes = 0x400 } end
                function ctx.io:stat()
                    if thrown then error(failure, 0) end
                    return nil, failure
                end
                local ok, err = pcall(incremental.physical_executable, ctx, root .. "/unobserved.stage")
                assert.is_false(ok)
                if type(failure) == "string" then assert.matches(failure, err, 1, true)
                else assert.equal(failure, err) end
            end
        end
    end)

    it("distinguishes direct Windows .com selection from an explicit LLVM stage", function()
        if not platform.windows then pending("Windows execution selection policies"); return end
        local path = root .. "/compiler-stage"
        write(path, "exact")
        write(path .. ".com", "direct")
        write(path .. ".exe", "llvm")
        windows_lookup(path, path .. ".com")
        windows_lookup(path, path, nil, "llvm")
        assert(os.remove(path))
        windows_lookup(path, path .. ".com")
        windows_lookup(path, path .. ".exe", nil, "llvm")
    end)

    it("retains an exact Windows directory as an LLVM execution failure", function()
        if not platform.windows then pending("Windows execution selection policies"); return end
        local path = root .. "/compiler.stage"
        assert(lfs.mkdir(path))
        write(path .. ".exe", "tool")
        windows_lookup(path, path .. ".exe")
        windows_lookup(path, false, nil, "llvm")
    end)

    it("selects Windows current-directory candidates only when that search is enabled", function()
        if not platform.windows then pending("Windows current-directory execution policy"); return end
        local directory, name = root .. "/PATH tools", "compiler-stage"
        assert(lfs.mkdir(directory))
        write(root .. "/" .. name .. ".exe", "cwd")
        write(directory .. "/" .. name .. ".exe", "path")
        windows_lookup(name, root .. "/" .. name .. ".exe", directory, nil, true)
        windows_lookup(name, directory .. "/" .. name .. ".exe", directory, nil, false)
        windows_lookup(name, directory .. "/" .. name .. ".exe", ";" .. directory .. ";;", nil, false)
    end)

    for _, quote in ipairs({ '"', "'" }) do
        it("retains a Windows PATH directory enclosed in " .. quote .. " quotes", function()
            if not platform.windows then pending("Windows quoted PATH selection"); return end
            local first, later = root .. "/quoted;tools", root .. "/later tools"
            assert(lfs.mkdir(first)); assert(lfs.mkdir(later))
            write(first .. "/compiler-stage.exe", "first")
            write(later .. "/compiler-stage.exe", "later")
            windows_lookup("compiler-stage", first .. "/compiler-stage.exe",
                quote .. first .. quote .. ";" .. later)
        end)
    end

    for _, stage in ipairs({ "unknown policy", "reported linker", "collect2", "lto-wrapper", "lto1" }) do
        it("permits publication without a final certificate for an uncertified Windows " .. stage, function()
            if not platform.windows then pending("Windows compiler-stage uncertainty"); return end
            seed_final()
            local options = { windows = true, compile_argv = { root .. "/cc", "-flto" } }
            if stage == "unknown policy" then options.compiler_stage_policy = "unknown"
            elseif stage == "reported linker" then options.link_flags = { "--ld-path=ld.lld" }
            elseif stage == "collect2" then description = ' "collect2"\n'
            elseif stage == "lto-wrapper" then
                description = ' "' .. root .. '/collect2" "-plugin-opt=lto-wrapper"\n'
            else stage_paths.lto1 = "lto1" end
            local ctx, ticket, tools = final_ticket(options)
            assert.is_string(tools.uncertified)
            assert.is_nil(tools.linker)
            assert.is_false(ticket.cacheable)
            assert.is_false(certificate.check(ctx, ticket))
            assert.same({}, ticket.dependency_argv)
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert(certificate.invalidate(ctx, ticket))
            assert(ctx.io:write_file(root .. "/program", "opaque image"))
            assert(certificate.commit(ctx, ticket))
            assert.is_nil(lfs.symlinkattributes(ticket.record))
            assert.is_nil(lfs.symlinkattributes(root .. "/.titan/linker-feature"))
            assert.equal(0, probes)
        end)
    end

    it("does not memoize a Windows linker verdict whose execution policy is unknown", function()
        if not platform.windows then pending("Windows compiler-stage uncertainty"); return end
        local options = clone(request)
        options.compiler_stage_policy = "unknown"
        local backend, reason, status = certificate.linker_backend(invocation(), options)
        assert.equal("none", backend)
        assert.is_string(reason)
        assert.equal("uncertified", status)
        assert.equal(0, probes)
        assert.is_nil(lfs.symlinkattributes(root .. "/.titan/linker-feature"))
    end)

    for _, kind in ipairs({ "unsupported query", "unrecognized wrapper" }) do
        it("keeps a normally running compiler with an " .. kind .. " explicitly uncacheable", function()
            if kind == "unsupported query" then
                description_result = { started = true, ok = false, why = "exit", status = 2,
                    output = "unsupported self-description" }
            else description = ' "' .. root .. '/opaque-wrapper"\n' end
            local ctx, ticket, tools = final_ticket()
            assert.is_string(tools.uncertified)
            assert.is_false(ticket.cacheable)
            assert(certificate.commit(ctx, ticket))
            assert.is_nil(lfs.symlinkattributes(ticket.record))
            local backend, reason, status = certificate.linker_backend(invocation(), request)
            assert.equal("none", backend)
            assert.is_string(reason)
            assert.equal("uncertified", status)
            assert.equal(0, probes)
            assert.is_nil(lfs.symlinkattributes(root .. "/.titan/linker-feature"))
        end)
    end

    for _, result in ipairs({
        { started = false, ok = false },
        { started = true, ok = false, why = "signal", status = 9 },
        { started = true, ok = false, interrupted = true, why = "exit", status = 1 },
        { started = true, ok = false, why = "unknown", status = 1 },
        { started = true, ok = false, why = "exit", status = 0 },
    }) do
        it("preserves a failed self-description transport without an uncertified-policy result", function()
            description_result = clone(result)
            description_result.diagnostic = "self-description transport failed"
            local tools, err = certificate.output_tools(invocation(), request)
            assert.is_nil(tools)
            assert.equal("self-description transport failed", err)
        end)
    end

    it("preserves physical-stage I/O errors and cancellation instead of treating them as policy uncertainty", function()
        for _, failure in ipairs({ "stage metadata failed", {} }) do
            local ctx = invocation()
            for _, method in ipairs({ "stat", "lstat" }) do
                local observe = ctx.io[method]
                ctx.io[method] = function(self, path)
                    if path:gsub("\\", "/"):lower() == (root .. "/ld"):lower() then
                        if type(failure) == "string" then return nil, failure end
                        error(failure, 0)
                    end
                    return observe(self, path)
                end
            end
            if type(failure) == "string" then
                local tools, err = certificate.output_tools(ctx, request)
                assert.is_nil(tools)
                assert.matches(failure, err, 1, true)
            else
                local ok, err = pcall(certificate.output_tools, ctx, request)
                assert.is_false(ok)
                assert.equal(failure, err)
            end
        end
    end)

    it("keeps the uncertified marker separate from requested native tool roles", function()
        local options = clone(request)
        options.tools = { uncertified = { "ar" } }
        local tools, err = certificate.output_tools(invocation(), options)
        assert.is_nil(tools)
        assert.matches("reserved native tool role", err, 1, true)
    end)

    it("uses a preclassified uncertain output request without further tool queries", function()
        local ctx, options = invocation(), clone(request)
        options.toolchain, options.uncacheable = nil, "compiler inventory is uncertified"
        function ctx.io:run() error("uncertified output request must not query native stages") end
        local tools = assert(certificate.output_tools(ctx, options))
        assert.same({ uncertified = options.uncacheable }, tools)
        local ticket = certificate.prepare(ctx, {
            output_root = root, outputs = { root .. "/program" }, objects = { root .. "/main.o" },
            toolchain = { output_tools = tools }, native_libraries = { backend = "gnu" },
        })
        assert.is_false(ticket.cacheable)
        assert.same({}, ticket.dependency_argv)
        assert.is_false(certificate.check(ctx, ticket))
        assert(certificate.commit(ctx, ticket))
        assert.is_nil(lfs.symlinkattributes(ticket.record))
    end)

    it("certifies the .exe selected from an absolute unsuffixed Windows compiler linker description", function()
        if not platform.windows then pending("Windows compiler-described executable suffix"); return end
        local reported, selected = root .. "/ld.lld", root .. "/ld.lld.exe"
        assert(os.remove(reported))
        write(selected, "tool")
        local shadow = root .. "/PATH shadow"
        assert(lfs.mkdir(shadow))
        write(shadow .. "/ld.lld.exe", "tool")
        description = ' "' .. reported .. '" "-o" "NUL"\n'
        local options = { windows = true }
        seed_final(options, shadow)
        local ctx, ticket, tools = final_ticket(options, shadow)
        assert.is_true(certificate.check(ctx, ticket))
        assert.equal(native_spelling(selected), tools.linker.identity.path)
        assert.same({ reported }, tools.linker.argv)
        local _, admitted = incremental.physical_executable(ctx, tools.linker.argv, options.compiler_stage_policy or "llvm")
        assert.equal(native_spelling(selected), admitted)
        assert.is_nil(ctx.io.reads[root .. "/main.o"])
        assert(model:context().io:write_file(shadow .. "/ld.lld.exe", "edit"))
        ctx, ticket = final_ticket(options, shadow)
        assert.is_true(certificate.check(ctx, ticket))
        assert.is_nil(ctx.io.reads[root .. "/main.o"])
        local stat = assert(lfs.attributes(selected))
        assert(model:context().io:write_file(selected, "edit"))
        assert(lfs.touch(selected, stat.access, stat.modification))
        ctx, ticket = final_ticket(options, shadow)
        assert.is_false(certificate.check(ctx, ticket))
        assert.is_nil(ctx.io.reads[root .. "/main.o"])
        assert.equal(stat.modification, lfs.attributes(selected, "modification"))
        assert.equal(stat.size, lfs.attributes(selected, "size"))
        assert.equal(0, resolves)
        assert.equal(0, probes)
    end)

    for _, case in ipairs({
        { "ar", { "ar" } }, { "ranlib", { "ranlib" } }, { "default RC", { "llvm-rc" } },
        { "explicit RC", { "llvm-rc", "/nologo" } }, { "dsymutil", { "dsymutil" } },
    }) do
        it("invalidates final output when unchanged " .. case[1] .. " argv selects another PATH tool", function()
            for _, directory in ipairs({ root .. "/one", root .. "/two" }) do
                assert(lfs.mkdir(directory))
                local path = directory .. "/" .. case[2][1] .. (platform.windows and ".exe" or "")
                write(path, "tool")
                model.executables[path] = true
            end
            local options = { tools = { auxiliary = case[2] }, compiler_argv = { root .. "/cc", "-fno-lto" } }
            seed_final(options, root .. "/one")
            local ctx, ticket, tools = final_ticket(options, root .. "/one")
            assert.is_true(certificate.check(ctx, ticket))
            assert.same(case[2], tools.auxiliary.argv)
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            ctx, ticket = final_ticket(options, root .. "/two")
            assert.is_false(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
        end)
    end

    for _, case in ipairs({
        { name = "disabled-LTO collect2", stage = "collect2", flags = { "-fno-lto" } },
        { name = "advertised plugin with native inputs", stage = "liblto_plugin.so", flags = {} },
    }) do
        it("invalidates a replaced " .. case.name .. " without probing unused LTO delegates", function()
            description = ' "' .. root .. '/collect2"'
            if case.stage == "liblto_plugin.so" then
                description = description .. ' "-plugin" "' .. root .. '/liblto_plugin.so" "-plugin-opt=' ..
                    root .. '/lto-wrapper"'
            end
            description = description .. "\n"
            local options = { link_flags = case.flags }
            seed_final(options)
            local ctx, ticket, tools = final_ticket(options)
            assert.is_true(certificate.check(ctx, ticket))
            assert.equal(native_spelling(root .. "/collect2"), tools.link_driver.identity.path)
            if case.stage == "liblto_plugin.so" then
                assert.equal(native_spelling(root .. "/liblto_plugin.so"), tools.lto_plugins[1].identity.path)
            else assert.is_nil(tools.lto_plugins) end
            assert.is_nil(tools.lto_wrapper)
            assert.is_nil(tools.lto_compiler)
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert(model:context().io:write_file(root .. "/" .. case.stage, "edit"))
            ctx, ticket = final_ticket(options)
            assert.is_false(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert.equal(3, resolves)
            assert.equal(3, descriptions)
        end)
    end

    for _, source in ipairs({ "compile flags", "bitcode payload" }) do
        it("resolves selected GCC LTO delegates for source-only " .. source, function()
            description = ' "' .. root .. '/collect2" "-plugin" "' .. root ..
                '/liblto_plugin.so" "-plugin-opt=' .. root .. '/lto-wrapper"\n'
            local options = {}
            if source == "compile flags" then options.compile_argv = { root .. "/cc", "-flto" }
            else
                write(root .. "/bitcode.o", "BC\192\222payload")
                options.inputs = { root .. "/bitcode.o" }
            end
            seed_final(options)
            local ctx, ticket, tools = final_ticket(options)
            assert.is_true(certificate.check(ctx, ticket))
            assert.equal(native_spelling(root .. "/lto-wrapper"), tools.lto_wrapper.identity.path)
            assert.equal(native_spelling(root .. "/lto1"), tools.lto_compiler.identity.path)
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
        end)
    end

    for _, stage in ipairs({ "liblto_plugin.so", "lto-wrapper", "lto1" }) do
        it("invalidates final output after selected GCC LTO stage replacement: " .. stage, function()
            description = "COLLECT_LTO_WRAPPER=" .. root .. '/lto-wrapper\n "' .. root ..
                '/collect2" "-plugin" "' .. root .. '/liblto_plugin.so" "-plugin-opt=' ..
                root .. '/lto-wrapper"\n'
            local options = { compiler_argv = { root .. "/cc", "-flto=auto" } }
            seed_final(options)
            local ctx, ticket, tools = final_ticket(options)
            assert.is_true(certificate.check(ctx, ticket))
            assert.equal(native_spelling(root .. "/liblto_plugin.so"), tools.lto_plugins[1].identity.path)
            assert.equal(native_spelling(root .. "/lto-wrapper"), tools.lto_wrapper.identity.path)
            assert.equal(native_spelling(root .. "/lto1"), tools.lto_compiler.identity.path)
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
            assert(model:context().io:write_file(root .. "/" .. stage, "edit"))
            ctx, ticket = final_ticket(options)
            assert.is_false(certificate.check(ctx, ticket))
            assert.is_nil(ctx.io.reads[root .. "/main.o"])
        end)
    end

    it("selects LTO from compile-only flags and bitcode payloads without probing disabled stages", function()
        description = ' "' .. root .. '/ld.lld" "-o" "/dev/null"\n'
        local _, _, tools = final_ticket({ compile_argv = { root .. "/cc", "-flto" } })
        assert.is_nil(tools.lto_compiler)
        assert.equal(0, resolves)
        write(root .. "/bitcode.o", "BC\192\222payload")
        local ctx = invocation()
        local options = clone(request)
        options.inputs = { root .. "/bitcode.o" }
        tools = assert(certificate.output_tools(ctx, options))
        assert.equal(native_spelling(root .. "/ld.lld"), tools.linker.identity.path)
        local before = resolves
        options.compiler_argv = { root .. "/cc", "-flto", "-fno-lto" }
        tools = assert(certificate.output_tools(invocation(), options))
        assert.is_nil(tools.lto_plugins)
        assert.is_nil(tools.lto_wrapper)
        assert.equal(before, resolves)
    end)

    it("invalidates a replaced Darwin LTO library without requiring executable mode", function()
        description = ' "' .. root .. '/ld" "-lto_library" "' .. root .. '/libLTO.dylib"\n'
        local options = { darwin = true, compiler_argv = { root .. "/cc", "-flto" } }
        seed_final(options)
        local ctx, ticket, tools = final_ticket(options)
        assert.is_true(certificate.check(ctx, ticket))
        assert.equal(native_spelling(root .. "/libLTO.dylib"), tools.lto_plugins[1].identity.path)
        assert.is_nil(tools.lto_compiler)
        assert(model:context().io:write_file(root .. "/libLTO.dylib", "edit"))
        ctx, ticket = final_ticket(options)
        assert.is_false(certificate.check(ctx, ticket))
        assert.is_nil(ctx.io.reads[root .. "/main.o"])
    end)

    it("rejects unresolved selected LTO stages and preserves cancellation identity", function()
        description = ' "' .. root .. '/collect2" "-plugin" "' .. root .. '/missing-plugin.so"\n'
        local options = clone(request)
        options.compiler_argv = { root .. "/cc", "-flto" }
        local tools, err = certificate.output_tools(invocation(), options)
        assert.is_nil(tools)
        assert.matches("missing-plugin.so", err, 1, true)
        local cancelled, ctx = {}, invocation()
        function ctx.io:run() error(cancelled, 0) end
        local ok, failure = pcall(certificate.output_tools, ctx, options)
        assert.is_false(ok)
        assert.equal(cancelled, failure)
    end)
end)

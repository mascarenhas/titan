local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local certificate = require "titan-compiler.linkcertificate"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
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

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

describe("final link certificates", function()
    local root, spec
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
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        for _, leaf in ipairs({ "main.o", "side.o", "helper.o", "payload.a", "provider.so", "runtime.a", "native.a", "program" }) do
            write(root .. "/" .. leaf, leaf .. " bytes")
        end
        write(root .. "/link.d", "program: " .. escape(root .. "/native.a") .. "\n")
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
    after_each(function() remove(root) end)

    it("accepts an unchanged complete output set without rewriting it", function()
        local ticket = commit()
        local old = os.time() - 60
        assert(lfs.touch(root .. "/program", old, old))
        assert(lfs.touch(ticket.record, old, old))
        assert.is_true(hit())
        assert.equal(old, lfs.attributes(root .. "/program", "modification"))
        assert.equal(old, lfs.attributes(ticket.record, "modification"))
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

    it("rehashes actual linker-reported libraries and scripts on a hit", function()
        commit()
        write(root .. "/native.a", "new native library bytes")
        local accepted, reason = hit()
        assert.is_false(accepted)
        assert.equal("native libraries changed", reason)
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

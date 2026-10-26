local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local native = require "titan-compiler.nativeinputs"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

local function context() return { io = compiler_io.new_sync() } end
local function write(path, bytes) assert(context().io:write_file(path, bytes)) end
local function remove(path)
    local kind = lfs.symlinkattributes(path, "mode")
    if kind == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif kind then assert(os.remove(path)) end
end

describe("normalized native inputs", function()
    it("orders defaults before environment before CLI and retains repeated flags", function()
        local normalized = assert(native.normalize({
            defaults = { cppflags = { "-DVALUE=0" }, cflags = { "-O0" }, ldflags = { "-Wl,default" } },
            env = { TITAN_EXTRA_CPPFLAGS = { "-DVALUE=1" }, TITAN_EXTRA_CFLAGS = { "-O1" },
                TITAN_EXTRA_LDFLAGS = { "-Lambient" } },
            cli = { ordered = {
                { kind = "define", value = "VALUE=2" }, { kind = "cflag", value = "-O2" },
                { kind = "include", value = "space Ω/include" }, { kind = "define", value = "VALUE=3" },
                { kind = "ldflag", value = "-Wl,--start-group" }, { kind = "library", value = "a,b" },
                { kind = "library", value = "a" }, { kind = "ldflag", value = "-Wl,--end-group" },
                { kind = "libdir", value = "space Ω/lib" },
            }, c_sources = { "first.c", "second.c" }, exe = "outside/bin/my app" },
        }))
        assert.same({ "-DVALUE=0", "-O0", "-DVALUE=1", "-O1", "-DVALUE=2", "-O2",
            "-Ispace Ω/include", "-DVALUE=3" }, normalized.compile_argv)
        assert.same({ "-Wl,default", "-Lambient", "-Wl,--start-group", "-la", "-lb", "-la",
            "-Wl,--end-group", "-Lspace Ω/lib" }, normalized.link_argv)
        assert.same({ "a", "b", "a" }, normalized.libraries)
        assert.same({ "first.c", "second.c" }, normalized.c_sources)
        assert.equal("outside/bin/my app", normalized.exe)
    end)

    it("tokenizes ambient strings once and keeps an explicit argument indivisible", function()
        local normalized = assert(native.normalize({ env = { TITAN_EXTRA_CPPFLAGS = '-I"space Ω/include"' },
            cli = { ordered = { { kind = "cflag", value = "-DNAME=one two" } } } }))
        assert.same({ "-Ispace Ω/include", "-DNAME=one two" }, normalized.compile_argv)
        assert.is_nil(native.normalize({ env = { TITAN_EXTRA_CFLAGS = "'unterminated" } }))
    end)

    it("separates pure link changes from compilation policy", function()
        local before = assert(native.normalize({ cli = { ordered = { { kind = "include", value = "inc" } } } }))
        local after = assert(native.normalize({ cli = { ordered = { { kind = "include", value = "inc" },
            { kind = "libdir", value = "lib" }, { kind = "library", value = "m" },
            { kind = "ldflag", value = "-pthread" } }, exe = "other" } }))
        assert.same(before.compile_argv, after.compile_argv)
        assert.same(before.cppflags, after.cppflags)
        assert.same(before.cflags, after.cflags)
        assert.not_same(before.link_argv, after.link_argv)
    end)
end)

describe("certified app-owned C sources", function()
    local root, source, header, phases
    local function build(extra, incremental_mode, sources, on_run)
        local ctx = context()
        local argv = assert(cdriver.split_shell_words(driver.CC))
        for _, flag in ipairs({ "-std=c99", "-fPIC", "-I" .. root }) do argv[#argv + 1] = flag end
        for _, flag in ipairs(extra or {}) do argv[#argv + 1] = flag end
        return native.compile(ctx, { sources = sources or { source }, output_root = root,
            compile_argv = argv, toolchain = "test-selected-toolchain", incremental = incremental_mode ~= false,
            run = function(command, phase)
                phases[#phases + 1] = phase
                local result = ctx.io:run(command)
                if on_run then on_run(phase, result) end
                return result
            end,
        })
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        source, header, phases = root .. "/helper Ω.c", root .. "/value.h", {}
        write(header, "#define VALUE 41\n")
        write(source, '#include "value.h"\nint helper(void) { return VALUE + 1; }\n')
    end)
    after_each(function() remove(root) end)

    it("preprocesses every invocation but compiles an unchanged node only once", function()
        local first = assert(build())[1]
        assert.is_false(first.hit)
        local old = os.time() - 60
        assert(lfs.touch(first.path, old, old))
        phases = {}
        local second = assert(build())[1]
        assert.is_true(second.hit)
        assert.equal(first.path, second.path)
        assert.equal(first.identity, second.identity)
        assert.equal(old, lfs.attributes(second.path, "modification"))
        assert.same({ "native-preprocess" }, phases)
    end)

    it("retires invocation scratch after publication, hits and native failures", function()
        local function clean()
            for name in lfs.dir(root .. "/.native") do
                if name ~= "." and name ~= ".." then
                    assert.truthy(name:match("^[0-9a-f]+%.o$") or name:match("^[0-9a-f]+%.record$"),
                        "retained native scratch: " .. name)
                end
            end
        end
        local first = assert(build())[1]
        clean()
        assert.is_true(assert(build())[1].hit)
        clean()
        write(source, "int helper(void) { return invalid; }\n")
        assert.is_nil(build())
        clean()
        write(source, '#include "missing_native_input.h"\n')
        assert.is_nil(build())
        clean()
        assert.equal("file", lfs.attributes(first.path, "mode"))
        assert.equal("file", lfs.attributes(first.path:gsub("%.o$", ".record"), "mode"))
    end)

    it("retires preprocessing scratch before propagating cancellation", function()
        local signal = {}
        local ok, err = pcall(function()
            build(nil, true, nil, function(phase)
                if phase == "native-preprocess" then error(signal, 0) end
            end)
        end)
        assert.is_false(ok)
        assert.equal(signal, err)
        for name in lfs.dir(root .. "/.native") do
            assert.truthy(name == "." or name == "..", "retained cancelled native scratch: " .. name)
        end
    end)

    it("recompiles changed source and transitive header bytes with preserved mtimes", function()
        local first = assert(build())[1]
        local old = lfs.attributes(header, "modification")
        write(header, "#define VALUE 42\n")
        assert(lfs.touch(header, old, old))
        local second = assert(build())[1]
        assert.is_false(second.hit)
        assert.not_equal(first.identity, second.identity)
        old = lfs.attributes(source, "modification")
        write(source, '#include "value.h"\nint helper(void) { return VALUE + 2; }\n')
        assert(lfs.touch(source, old, old))
        assert.is_false(assert(build())[1].hit)
    end)

    it("certifies forced headers and computed includes using native preprocessing", function()
        write(root .. "/forced.h", '#define HEADER "value.h"\n')
        write(source, '#include HEADER\nint helper(void) { return VALUE; }\n')
        local first = assert(build({ "-include", root .. "/forced.h" }))[1]
        assert.is_true(assert(build({ "-include", root .. "/forced.h" }))[1].hit)
        write(root .. "/other.h", "#define VALUE 84\n")
        write(root .. "/forced.h", '#define HEADER "other.h"\n')
        local changed = assert(build({ "-include", root .. "/forced.h" }))[1]
        assert.is_false(changed.hit)
        assert.not_equal(first.identity, changed.identity)
    end)

    it("detects presence-query changes without a previously positive dependency", function()
        write(source, [[
#if __has_include("optional.h")
int helper(void) { return 1; }
#else
int helper(void) { return 2; }
#endif
]])
        local first = assert(build())[1]
        write(root .. "/optional.h", "/* presence alone changes code */\n")
        local second = assert(build())[1]
        assert.is_false(second.hit)
        assert.not_equal(first.identity, second.identity)
        assert(os.remove(root .. "/optional.h"))
        assert.is_false(assert(build())[1].hit)
    end)

    it("deduplicates canonical aliases while preserving first-source order", function()
        local second = root .. "/second.c"
        write(second, "int second(void) { return 2; }\n")
        local objects = assert(build(nil, true, { source, second, source, root .. "/./helper Ω.c" }))
        assert.equal(2, #objects)
        assert.equal(source, objects[1].source)
        assert.equal(second, objects[2].source)
        if not platform.windows then
            assert(lfs.link(source, root .. "/alias.c", true))
            assert.equal(1, #assert(build(nil, true, { source, root .. "/alias.c" })))
        end
    end)

    it("uses distinct deterministic identities for same-basename sources", function()
        assert(lfs.mkdir(root .. "/other"))
        local second = root .. "/other/helper Ω.c"
        write(second, "int other(void) { return 7; }\n")
        local objects = assert(build(nil, true, { source, second }))
        assert.not_equal(objects[1].path, objects[2].path)
        local again = assert(build(nil, true, { source, second }))
        assert.equal(objects[1].path, again[1].path)
        assert.equal(objects[2].path, again[2].path)
    end)

    it("repairs missing and tampered objects and invalid sidecars", function()
        local first = assert(build())[1]
        write(first.path, "not an object")
        assert.is_false(assert(build())[1].hit)
        assert(os.remove(first.path))
        assert.is_false(assert(build())[1].hit)
        write(first.path:gsub("%.o$", ".record"), "untrusted executable text")
        assert.is_false(assert(build())[1].hit)
    end)

    it("forces native compilation for a non-incremental request", function()
        assert(build())
        phases = {}
        assert.is_false(assert(build(nil, false))[1].hit)
        assert.same({ "native-preprocess", "native-compile" }, phases)
    end)

    it("leaves no accepted new record after a compiler failure", function()
        local first = assert(build())[1]
        write(source, "int helper(void) { return invalid; }\n")
        local objects = build()
        assert.is_nil(objects)
        write(source, "int helper(void) { return 7; }\n")
        assert.is_false(assert(build())[1].hit)
        assert.equal(first.path, assert(build())[1].path)
    end)

    it("rejects an observed header edit during native compilation", function()
        local changed = false
        local objects, err = build(nil, true, nil, function(phase)
            if phase == "native-compile" then
                changed = true
                write(header, "#define VALUE 99\n")
            end
        end)
        assert.is_true(changed)
        assert.is_nil(objects)
        assert.matches("native dependency changed during compilation", err, 1, true)
        local accepted = assert(build())[1]
        assert.is_false(accepted.hit)
    end)
end)

describe("opaque native C policy", function()
    it("does not reuse an object whose compiler options come from a response file", function()
        local root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        local ok, err = pcall(function()
            write(root .. "/helper.c", "int helper(void) { return VALUE; }\n")
            write(root .. "/flags", "-DVALUE=1\n")
            local command = assert(cdriver.split_shell_words(driver.CC))
            command[#command + 1] = "@" .. root .. "/flags"
            local request = { sources = { root .. "/helper.c" }, output_root = root,
                compile_argv = command, toolchain = "selected-toolchain", incremental = true }
            local first = assert(native.compile(context(), request))[1]
            local second = assert(native.compile(context(), request))[1]
            assert.is_false(first.cacheable)
            assert.is_false(second.hit)
            write(root .. "/flags", "-DVALUE=2\n")
            local third = assert(native.compile(context(), request))[1]
            assert.is_false(third.hit)
            assert.not_equal(first.identity, third.identity)
        end)
        remove(root)
        assert.is_true(ok, tostring(err))
    end)
end)

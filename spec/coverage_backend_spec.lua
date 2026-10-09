local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local coverage = require "titan-compiler.coverage"
local driver = require "titan-compiler.driver"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local sha256 = require "titan-compiler.sha256"
local temporary = require "spec.support.temporary"
local ROOT = lfs.currentdir()
local LUA = installed_prefix.active() .. (platform.windows and "/bin/lua.exe" or "/bin/lua")

describe("explicit native coverage backend configuration", function()
    local root, previous_windows, previous_getenv
    before_each(function()
        root = temporary.name("-coverage-backend")
        os.remove(root); assert(lfs.mkdir(root))
        previous_windows, previous_getenv = platform.windows, platform.getenv
        platform.getenv = function() return nil end
    end)
    after_each(function()
        platform.windows, platform.getenv = previous_windows, previous_getenv
        driver.remove_path(root)
    end)

    local function args(backend)
        return { coverage = root .. "/build", coverage_root = root,
            coverage_module = { "app.calc" }, tree = root .. "/source",
            coverage_backend = backend, _coverage_frontend = lfs.currentdir() .. "/titanc" }
    end

    local function tools(backend, change)
        local cc = backend == "llvm-gcov" and '"C:\\Program Files\\Clang\\clang.exe"' or "gcc-14"
        local cc_argv = assert(driver.split_shell_words(cc))
        local prefix = { table.unpack(cc_argv) }
        for _, flag in ipairs({ "-std=c99", "-I", "C:/SDK includes", "-g" }) do prefix[#prefix + 1] = flag end
        local fake_driver = { EMIT_LINE_DIRECTIVES = true, CC = cc, EXTRA_LDFLAGS = {},
            split_shell_words = driver.split_shell_words,
            generated_compile_prefix = function() return prefix end }
        local calls = {}
        local strategy = {
            realpath = function(_, filename) return filename end,
            run = function(_, argv)
                calls[#calls + 1] = argv
                if change then
                    local answer = change(argv)
                    if answer then return answer end
                end
                local final = argv[#argv]
                if argv[1] == cc_argv[1] then
                    if final == "-dumpmachine" then return { ok = true, output = "x86_64-w64-windows-gnu\n" } end
                    if final == "-dumpfullversion" then return { ok = true, output = "14.2.0\n" } end
                    return { ok = true, output = backend == "llvm-gcov" and "clang version 22.1.8\n" or "gcc 14.2.0\n" }
                elseif final == "--version" then
                    return { ok = true, output = backend == "llvm-gcov" and "LLVM version 22.1.8\n" or "gcov 14.2.0\n" }
                end
                return { ok = true, output = '{"backend":"' .. backend .. '","checks":{"passed":true}}\n' }
            end,
        }
        return fake_driver, strategy, calls, prefix
    end

    it("keeps GCC as the default and rejects it on Windows before tool execution", function()
        platform.windows = true
        local d, io, calls = tools("gcc-gcov")
        local build, err = coverage.prepare(d, args(), io)
        assert.is_nil(build); assert.matches("gcc-gcov is unsupported", err, 1, true)
        assert.same({}, calls)
        assert.is_nil(lfs.attributes(root .. "/build"))
    end)

    it("rejects default and explicit GCC in the CLI before foreign C configuration", function()
        local prelude = 'package.path = ' .. string.format("%q", ROOT .. "/?.lua;")
            .. ' .. package.path; local driver = require "titan-compiler.driver"; '
            .. 'local platform = require "titan-compiler.platform"; '
            .. 'platform.windows = true; platform.getenv = os.getenv; '
            .. 'driver.new_resolver_context = function() return {} end; '
            .. 'driver.configure_foreign_c = function() '
            .. 'io.stderr:write("FOREIGN_CONFIGURATION_REACHED\\n"); os.exit(77) end; '
        for _, backend in ipairs({ "default", "gcc-gcov", "llvm-gcov" }) do
            local arguments = { "--coverage", root .. "/cli-build",
                "--coverage-module", "missing", "missing" }
            if backend ~= "default" then
                table.insert(arguments, 1, backend)
                table.insert(arguments, 1, "--coverage-backend")
            end
            local encoded = {}
            for _, argument in ipairs(arguments) do encoded[#encoded + 1] = string.format("%q", argument) end
            local source = prelude .. 'arg = { ' .. table.concat(encoded, ", ")
                .. ' }; arg[0] = ' .. string.format("%q", ROOT .. "/titanc")
                .. '; dofile(arg[0])'
            local result = compiler_io.new_sync():run({ LUA, "-e", source }, { stderr_to_stdout = true })
            assert.is_false(result.ok)
            if backend == "llvm-gcov" then
                assert.matches("FOREIGN_CONFIGURATION_REACHED", result.output, 1, true)
            else
                assert.matches("gcc-gcov is unsupported by the Windows CLANG64 SDK", result.output, 1, true)
                assert.is_nil(result.output:find("FOREIGN_CONFIGURATION_REACHED", 1, true))
            end
            assert.is_nil(lfs.attributes(root .. "/cli-build"))
        end
    end)

    it("rejects unknown backends and LLVM on a Unix host before tool execution", function()
        platform.windows = false
        local d, io, calls = tools("llvm-gcov")
        local build, err = coverage.prepare(d, args("unknown"), io)
        assert.is_nil(build); assert.matches("unsupported native coverage backend", err, 1, true)
        build, err = coverage.prepare(d, args("llvm-gcov"), io)
        assert.is_nil(build); assert.matches("requires the Windows x64", err, 1, true)
        assert.same({}, calls)
    end)

    it("requires the exact LLVM release and target before creating build artifacts", function()
        platform.windows = true
        for _, override in ipairs({
            function(argv)
                if argv[1]:find("clang.exe", 1, true) and argv[#argv] == "--version" then
                    return { ok = true, output = "clang version 22.1.80\n" }
                end
            end,
            function(argv)
                if argv[#argv] == "-dumpmachine" then return { ok = true, output = "x86_64-pc-windows-msvc\n" } end
            end,
            function(argv)
                if argv[1] == "llvm-cov" then return { ok = true, output = "LLVM version 22.1.7\n" } end
            end,
        }) do
            local d, io = tools("llvm-gcov", override)
            local build, err = coverage.prepare(d, args("llvm-gcov"), io)
            assert.is_nil(build); assert.matches("requires", err, 1, true)
            assert.is_nil(lfs.attributes(root .. "/build"))
        end
    end)

    it("passes the exact compiler arguments and durable runner directory to the explicit Python command", function()
        platform.windows = true
        local d, io, calls = tools("llvm-gcov")
        local options = args("llvm-gcov")
        options.coverage_python = '"C:\\Private Python\\python.exe" -I -S -B'
        local build, err = coverage.prepare(d, options, io)
        assert.truthy(build, err)
        local command = calls[#calls]
        assert.same({ "C:\\Private Python\\python.exe", "-I", "-S", "-B" },
            { command[1], command[2], command[3], command[4] })
        assert.equal("llvm-gcov", build.backend)
        assert.equal("llvm-cov gcov", build.settings.gcov)
        assert.same({ format = "llvm-gcov", gcov_prefix_strip = 1 }, build.settings.counter_policy)
        local found = {}
        for index, argument in ipairs(command) do found[argument] = index end
        assert.equal("llvm-gcov", command[found["--backend"] + 1])
        assert.equal(path.join(build.directory, "tools"), command[found["--runner-directory"] + 1])
        for _, argument in ipairs({ "--compile-arg=-std=c99", "--compile-arg=-I",
            "--compile-arg=C:/SDK includes", "--compile-arg=-g" }) do assert.truthy(found[argument]) end
        assert.is_nil(found["--compile-arg=C:\\Program Files\\Clang\\clang.exe"])
        assert.matches('"backend":"llvm-gcov"', build.settings.backend_probe, 1, true)
    end)

    it("preserves GCC probe argv and relocation policy", function()
        platform.windows = false
        local d, io, calls = tools("gcc-gcov")
        local build, err = coverage.prepare(d, args(), io)
        assert.truthy(build, err)
        local command = calls[#calls]
        assert.equal("python3", command[1]); assert.equal("probe", command[3])
        assert.same({ "--cc", "gcc-14", "--gcov", "gcov" },
            { command[4], command[5], command[6], command[7] })
        assert.equal(7, #command)
        assert.same({ format = "gcc-gcov", gcov_prefix_strip = 0 }, build.settings.counter_policy)
    end)

    it("fails a silent successful probe instead of emitting an unverified build", function()
        platform.windows = true
        local d, io = tools("llvm-gcov", function(argv)
            if argv[2] and argv[2]:find("titan-coverage", 1, true) then return { ok = true, output = "" } end
        end)
        local build, err = coverage.prepare(d, args("llvm-gcov"), io)
        assert.is_nil(build); assert.matches("capability probe failed", err, 1, true)
        assert.is_nil(lfs.attributes(root .. "/build/build.config"))
    end)

    it("rejects ambient auxiliary-output flags before executing the capability probe", function()
        platform.windows = true
        for _, flag in ipairs({ "-dumpdir", "-dumpdir=elsewhere", "-dumpbase", "-fno-profile-instr-generate" }) do
            local d, io, calls, prefix = tools("llvm-gcov")
            prefix[#prefix + 1] = flag
            local build, err = coverage.prepare(d, args("llvm-gcov"), io)
            assert.is_nil(build)
            assert.matches("coverage flags must be owned", err, 1, true)
            assert.equal(3, #calls)
            assert.is_nil(lfs.attributes(root .. "/build/build.config"))
        end
    end)

    it("does not probe a compiler different from the effective generated compile prefix", function()
        platform.windows = true
        local d, io, calls, prefix = tools("llvm-gcov")
        prefix[1] = "another-clang.exe"
        local build, err = coverage.prepare(d, args("llvm-gcov"), io)
        assert.is_nil(build)
        assert.matches("compiler prefix does not match", err, 1, true)
        assert.equal(3, #calls)
        assert.is_nil(lfs.attributes(root .. "/build/build.config"))
    end)

    it("uses stable owner directories for LLVM notes without retaining foreign C declarations", function()
        local build = { directory = root, selected = { ["one.leaf"] = true, ["two.leaf"] = true }, backend = "llvm-gcov" }
        for _, name in ipairs({ "one.leaf", "two.leaf" }) do
            local flags = coverage.compile_flags(build, name)
            assert.same({ "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic", "-dumpdir",
                root .. "/objects/" .. name:match("^(.-)[.]") .. "/" }, flags)
        end
        assert.same({ "-O0", "-fno-lto" }, coverage.compile_flags(build, "tests"))
        build.backend = "gcc-gcov"
        assert.same({ "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic", "-fkeep-static-functions",
            "-dumpbase", "leaf.c", "-dumpbase-ext", ".c" }, coverage.compile_flags(build, "one.leaf"))
    end)

    it("hashes complete binary coverage artifacts and CRLF source bytes", function()
        local directory = root .. "/build"
        assert(lfs.mkdir(directory)); assert(lfs.mkdir(directory .. "/objects"))
        local filename = root .. "/app.titan"
        local object, notes, anchors = directory .. "/objects/app.o",
            directory .. "/objects/app.gcno", directory .. "/objects/app.coverage-anchors"
        local provider, payload = root .. "/app.dll", root .. "/payload.a"
        local bytes = {
            [filename] = "function answer(): integer\r\n  return 7\r\nend\r\n",
            [object] = "\0COFF\r\n\26object suffix\255",
            [notes] = "oncg*11B\26notes suffix\0\r\n",
            [anchors] = filename .. "\0" .. "2\n",
            [provider] = "MZ\0\r\n\26provider suffix\0",
            [payload] = "!<arch>\r\n\26payload suffix\0",
        }
        local function write(filename, contents)
            local file = assert(io.open(filename, "wb"))
            assert(file:write(contents)); assert(file:close())
        end
        for name, contents in pairs(bytes) do write(name, contents) end
        local build = { directory = directory, selected = { app = true }, modules = { "app" },
            root = root, root_identity = root, mappings = {}, settings = {},
            receipts = {}, source_entries = {}, source_hashes = {},
            strategy = { realpath = function(_, name) return name end } }
        local source = { files = { filename }, main = filename }

        -- Model the CRT's text reads on every host, so a POSIX run also catches
        -- accidental use of the general text helper for coverage byte identity.
        local open = io.open
        io.open = function(name, mode)
            if bytes[name] and mode == "r" then
                local contents = bytes[name]:match("^[^\26]*"):gsub("\r\n", "\n")
                return { read = function() return contents end, close = function() return true end }
            end
            return open(name, mode)
        end
        local ok, err = xpcall(function()
            assert(coverage.source(build, "app", source, {}))
            assert.equal(sha256.hex(bytes[filename]), build.source_hashes.app[filename])
            assert(coverage.write_manifest(build, {
                app = { kind = "source", filename = filename, source_files = { filename } },
            }, { app = object }, { { path = provider, objects = { object } } }, { payload }))
            local file = assert(open(directory .. "/build.json", "rb"))
            local manifest = file:read("a"); assert(file:close())
            for _, name in ipairs({ filename, object, notes, provider, payload }) do
                assert.truthy(manifest:find(sha256.hex(bytes[name]), 1, true), name)
            end
            assert.matches('"notes_sha256":"' .. sha256.hex(bytes[notes]) .. '"', manifest, 1, true)
            local forced = {}
            assert(coverage.source(build, "app", source, forced))
            assert.is_nil(forced.app)
            local attributes = assert(lfs.attributes(object))
            bytes[object] = bytes[object]:sub(1, -2) .. "\254"
            write(object, bytes[object])
            assert(lfs.touch(object, attributes.access, attributes.modification))
            assert.equal(attributes.size, lfs.attributes(object, "size"))
            assert.equal(attributes.modification, lfs.attributes(object, "modification"))
            forced = {}
            assert(coverage.source(build, "app", source, forced))
            assert.is_true(forced.app)
        end, debug.traceback)
        io.open = open
        assert(ok, err)
    end)

    it("preserves captured generated source contents without requiring a physical source", function()
        local filename = root .. "/generated.titan"
        local bytes = "function generated(): integer\r\n  return 9\r\nend\r\n"
        local build = { directory = root, selected = {}, receipts = {},
            source_entries = {}, source_hashes = {} }
        assert(coverage.source(build, "generated", { files = { filename },
            contents = { [filename] = bytes } }, {}))
        assert.equal(sha256.hex(bytes), build.source_hashes.generated[filename])
        assert.is_nil(lfs.attributes(filename))
        local physical = assert(io.open(filename, "wb"))
        assert(physical:write("different physical source\r\n")); assert(physical:close())
        assert(coverage.source(build, "generated", { files = { filename },
            contents = { [filename] = bytes } }, {}))
        assert.equal(sha256.hex(bytes), build.source_hashes.generated[filename])
    end)
end)

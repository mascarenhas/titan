local assert = require "luassert"
local coverage = require "titan-compiler.coverage"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

describe("native coverage source build", function()
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

    local function prepare(options, backend, change)
        options = options or {}
        options.coverage, options.coverage_output = true, root .. "/report"
        options.coverage_backend = backend or options.coverage_backend
        backend = options.coverage_backend or (platform.windows and "llvm-gcov" or "gcc-gcov")
        local cc = backend == "llvm-gcov" and "clang" or "gcc"
        local fake_driver = { EMIT_LINE_DIRECTIVES = true, CC = cc,
            split_shell_words = driver.split_shell_words }
        local calls = {}
        local strategy = { run = function(_, argv)
            calls[#calls + 1] = argv
            if change then
                local result = change(argv)
                if result then return result end
            end
            if argv[#argv] == "-dumpfullversion" then return { ok = true, output = "14.2.0\n" } end
            return { ok = true, output = argv[1] == "clang" and "clang version 22.1.8\n" or
                argv[1] == "llvm-cov" and "LLVM version 22.1.8\n" or "gcov (GCC) 14.2.0\n" }
        end }
        local build, err = coverage.prepare(fake_driver, options, strategy)
        return build, err, calls
    end

    it("selects source graph modules and excludes a whole module containing test_ functions", function()
        local build = assert(prepare())
        local imported = {
            app = { kind = "source", ast = {} },
            helper = { kind = "source", ast = {} },
            tests = { kind = "source", ast = {
                { _tag = "Ast.TopLevelFunc", name = "test_private", islocal = true },
                { _tag = "Ast.TopLevelFunc", name = "production" },
            } },
            prebuilt = { kind = "dynamic" },
            archive = { kind = "static" },
        }
        assert(coverage.select(build, imported))
        assert.same({ "app", "helper" }, build.modules)
        assert.is_nil(build.selected.tests)
    end)

    it("unions whole-name * and ? globs over source modules only", function()
        local build = assert(prepare({ coverage_module = { "myapp.*", "other.?" } }))
        local imported = {}
        for _, name in ipairs({ "myapp.one", "myapp.deep.two", "other.x", "other.xy", "prefix.myapp.one" }) do
            imported[name] = { kind = "source", ast = {} }
        end
        imported["myapp.prebuilt"] = { kind = "static" }
        imported["myapp.tests"] = { kind = "source", ast = {
            { _tag = "Ast.TopLevelFunc", name = "test_case" } } }
        assert(coverage.select(build, imported))
        assert.same({ "myapp.deep.two", "myapp.one", "other.x" }, build.modules)
        local empty = assert(prepare({ coverage_module = { "missing.*" } }))
        local ok, err = coverage.select(empty, imported)
        assert.is_nil(ok); assert.matches("coverage selection is empty", err, 1, true)
        local invalid, invalid_error = prepare({ coverage_module = { "app.[x]" } })
        assert.is_nil(invalid); assert.matches("use logical module names with * and ?", invalid_error, 1, true)
    end)

    it("keeps source outputs in their adjacent .coverage directory and leaves executable paths alone", function()
        local build = assert(prepare())
        local source = { kind = "flat", main = root .. "/app.titan", files = { root .. "/app.titan" },
            program_output = root .. "/app" }
        assert(coverage.source(build, "app", source))
        assert.equal(path.join(root, ".coverage", "app.titan"), source.native_output)
        assert.equal(root .. "/app", source.program_output)
        assert(coverage.source(build, "app", source))
        assert.equal(path.join(root, ".coverage", "app.titan"), source.native_output)
        local generated = { kind = "generated", main = root .. "/runner.titan" }
        assert(coverage.source(build, "runner", generated))
        assert.is_false(coverage.matches(build, "runner", {}))
    end)

    it("reconstructs the executable list from fresh and reused object records", function()
        local build = assert(prepare({ coverage_format = { "html", "lcov" } }))
        local source, first, second = root .. "/first.titan", root .. "/.coverage/first.c", root .. "/.coverage/second.c"
        local left = coverage.partial({ { filename = first,
            anchors = { [source] = { [2] = true, [5] = true } } } }, { source }, build.backend)
        local right = coverage.partial({ { filename = second, anchors = {} } }, { source }, build.backend)
        local imported = {
            first = { kind = "source", ast = {}, coverage = left },
            second = { kind = "source", object_metadata = { coverage = right, coverage_test_functions = {} } },
        }
        assert(coverage.select(build, imported))
        local config = assert(coverage.inventory(build, imported))
        assert.same({ coverage.absolute(first), coverage.absolute(second) }, config.files)
        assert.same({ coverage.absolute(source) }, config.sources)
        assert.same({ 2, 5 }, config.anchors[coverage.absolute(first)][coverage.absolute(source)])
        assert.same({ "html", "lcov" }, config.formats)
        assert.same(config, assert(load("return " .. coverage.serialize(config), "config", "t", {}))())
        assert.equal("directory", lfs.attributes(config.output, "mode"))
    end)

    it("preserves matching backend diagnostics without Python or a capability protocol", function()
        platform.windows = false
        local build, err, calls = prepare()
        assert.truthy(build, err); assert.same({ "gcov" }, build.gcov)
        assert.equal(3, #calls)
        platform.windows = true
        build, err = prepare()
        assert.truthy(build, err); assert.equal("llvm-gcov", build.backend)
        assert.same({ "llvm-cov", "gcov" }, build.gcov)
        build, err, calls = prepare({}, "gcc-gcov")
        assert.is_nil(build); assert.matches("gcc-gcov is unsupported", err, 1, true)
        assert.same({}, calls)
        build, err = prepare({}, "llvm-gcov", function(argv)
            if argv[1] == "llvm-cov" then return { ok = true, output = "LLVM version 22.1.7\n" } end
        end)
        assert.is_nil(build); assert.matches("matching LLVM 22.1.8", err, 1, true)
    end)

    it("keeps notes beside generated C even when object publication uses a temporary pathname", function()
        platform.windows = false
        local build = assert(prepare())
        assert(coverage.source(build, "one.leaf", { main = root .. "/one/leaf.titan" }))
        build.selected["one.leaf"] = true
        assert.same({ "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic", "-fkeep-static-functions",
            "-dumpbase", "leaf.c", "-dumpbase-ext", ".c" }, coverage.compile_flags(build, "one.leaf"))
        build.backend = "llvm-gcov"
        assert.same({ "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic", "-dumpdir",
            coverage.absolute(root .. "/one/.coverage") .. "/" }, coverage.compile_flags(build, "one.leaf"))
        assert.same({ "-O0", "-fno-lto" }, coverage.compile_flags(build, "tests"))
    end)

    it("uses the logical target-selection stem for coverage notes and dumpbase", function()
        platform.windows = false
        local build = assert(prepare())
        local source = { kind = "flat", main = root .. "/foo.linux.titan",
            native_output = root .. "/foo.titan", files = { root .. "/foo.linux.titan" } }
        assert(coverage.source(build, "foo", source))
        assert.equal(path.join(root, ".coverage", "foo.titan"), source.native_output)
        build.selected.foo = true
        assert.same({ "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic",
            "-fkeep-static-functions", "-dumpbase", "foo.c", "-dumpbase-ext", ".c" },
            coverage.compile_flags(build, "foo"))
        assert.same({ root .. "/foo.linux.titan" }, source.files)
    end)
end)

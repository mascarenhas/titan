local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local graphcodec = require "titan-compiler.graphcodec"
local playground = require "titan-compiler.playground"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local installed_prefix = require "spec.support.installed_prefix"
local toolchain = require "spec.support.browser_toolchain"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"

local strategy = compiler_io.new_sync()
local PREFIX = installed_prefix.active()
local SDK = driver.installed_paths(PREFIX, "browser").titan_bin

local function read(filename)
    return assert(strategy:read_file(filename))
end

local function run(argv, directory)
    local previous = directory and assert(lfs.currentdir())
    if directory then assert(lfs.chdir(directory)) end
    local called, result = pcall(strategy.run, strategy, argv, { stderr_to_stdout = true })
    if previous then assert(lfs.chdir(previous)) end
    assert.is_true(called, result)
    return result.ok, result.output or result.diagnostic or ""
end

describe("in-memory compiler I/O", function()
    it("owns its files and directories without a host filesystem or processes", function()
        local io = compiler_io.new_memory({ cwd = "/project", files = { ["/project/a/main.titan"] = "main" } })
        compiler_io.validate(io)
        assert.equal("/project", io:cwd())
        assert.equal("file", io:stat("a/main.titan").kind)
        assert.equal(4, io:stat("/project/a/main.titan").size)
        assert.equal("directory", io:lstat("/project/a").kind)
        assert.is_nil((io:stat("missing.titan")))
        assert.equal("/project/a/main.titan", io:realpath("./a/../a/main.titan"))
        assert.equal("mai", io:read_file("a/main.titan", 2))
        assert.is_true(io:readable("a/main.titan"))
        assert.same({ "a" }, io:list("/project"))
        assert.is_nil((io:write_file("b/new.titan", "x")))
        assert.is_true(io:mkdir("b"))
        assert.is_true(io:write_file("b/new.titan", "x"))
        assert.is_true(io:rename("b/new.titan", "b/moved.titan"))
        assert.same({ "moved.titan" }, io:list("b"))
        assert.is_nil((io:rmdir("b")))
        assert.is_true(io:unlink("b/moved.titan"))
        assert.is_true(io:rmdir("b"))
        local reserved = io:tmpname()
        assert.equal("", io:read_file(reserved))
        local result = io:run({ "clang", "--version" })
        assert.is_false(result.started)
        assert.is_false(result.ok)
        assert.has_error(function() compiler_io.new_memory({ cwd = "relative" }) end)
    end)

    it("keeps one coherent namespace with unique reservations and POSIX renames", function()
        for _, files in ipairs({
            { ["/a"] = "file", ["/a/b"] = "nested" },
            { ["/a/b/c"] = "nested", ["/a/b"] = "file" },
            { ["/x"] = "one", ["/./x"] = "two" },
        }) do
            assert.has_error(function() compiler_io.new_memory({ files = files }) end)
        end
        assert.has_error(function() compiler_io.new_memory({ cwd = "/w", files = { ["/w"] = "file" } }) end)

        local io = compiler_io.new_memory({ files = { ["/.titan-temporary/1"] = "kept" } })
        local reserved = io:tmpname()
        assert.are_not.equal("/.titan-temporary/1", reserved)
        assert.equal("kept", io:read_file("/.titan-temporary/1"))
        assert.equal("", io:read_file(reserved))
        assert.are_not.equal(reserved, io:tmpname())

        for _, limit in ipairs({ -1, 1.5, math.maxinteger, 0 / 0, math.huge, "2" }) do
            local bytes, err = io:read_file("/.titan-temporary/1", limit)
            assert.is_nil(bytes)
            assert.equal("read limit must be a nonnegative integer", err)
        end
        assert.equal("k", io:read_file("/.titan-temporary/1", 0))

        io = compiler_io.new_memory({ cwd = "/w", files = {
            ["/src/a.titan"] = "a", ["/src/sub/b.titan"] = "b", ["/full/x"] = "x" } })
        assert.truthy(io:mkdir("/empty"))
        assert.is_true(io:rename("/src", "/empty"))
        assert.is_nil((io:stat("/src")))
        assert.equal("b", io:read_file("/empty/sub/b.titan"))
        assert.same({ "a.titan", "sub" }, io:list("/empty"))
        assert.is_nil((io:rename("/empty", "/full")))
        assert.is_nil((io:rename("/empty", "/empty/sub/inner")))
        assert.is_nil((io:rename("/", "/root")))
        assert.is_nil((io:rename("/empty/a.titan", "/empty/sub")))
        assert.is_nil((io:rename("/empty", "/full/x")))
        assert.is_nil((io:rename("/w", "/elsewhere")))
        assert.is_true(io:rename("/empty/a.titan", "/full/x"))
        assert.equal("a", io:read_file("/full/x"))
    end)
end)

-- The installed browser SDK's semantic assets: pending without the browser
-- toolchain and SDK, an error under TITAN_REQUIRE_BROWSER_TOOLCHAIN=1.
local function semantic_assets()
    local info, why = toolchain.require({ sdk = true })
    if not info then return nil, why end
    local native = assert(driver.browser_analysis_target(PREFIX))
    return {
        native = native,
        catalog = assert(driver.browser_analysis_catalog(native)),
        analysis_target = read(path.join(SDK, "analysis-target")),
        absent_modules = read(path.join(SDK, "absent-modules")),
    }
end

local function memory_pack(assets, root)
    local directory = driver.installed_paths(root, "browser").titan_bin
    return compiler_io.new_memory({ files = {
        [directory .. "/analysis-target"] = assets.analysis_target,
        [directory .. "/absent-modules"] = assets.absent_modules,
    } })
end

describe("browser semantic catalog", function()
    local saved_imported, saved_registry
    before_each(function() saved_imported, saved_registry = driver.imported, types.registry end)
    after_each(function() driver.imported, types.registry = saved_imported, saved_registry end)

    it("rehydrates the scanned provider without reading its archive", function()
        local assets, why = semantic_assets()
        if not assets then pending(why); return end
        assert.equal(assets.catalog, assert(driver.browser_analysis_catalog(assets.native)))
        local handle = assert(driver.browser_analysis_target("/sdk",
            { io = memory_pack(assets, "/sdk"), catalog = assets.catalog }))
        assert.equal(assets.native.identity, handle.identity)
        assert.equal(driver.installed_paths("/sdk", "browser").titan_bin .. "/titan.a", handle.provider_file)
        local again, again_error = driver.browser_analysis_catalog(handle)
        assert.is_nil(again)
        assert.matches("scanned from its archive", again_error)

        local catalog = assert(graphcodec.decode(assets.catalog))
        catalog.provider_sha256 = string.rep("0", 64)
        local stale, stale_error = driver.browser_analysis_target("/sdk",
            { io = memory_pack(assets, "/sdk"), catalog = graphcodec.encode(catalog) })
        assert.is_nil(stale)
        assert.matches("does not describe the provider analysis%-target names", stale_error)
    end)

    it("serves one analysis-only or one emit-only context per handle", function()
        local assets, why = semantic_assets()
        if not assets then pending(why); return end
        local handle = assets.native
        for _, options in ipairs({
            { target = "browser", browser_analysis_target = handle },
            { target = "browser", analysis_only = true, emit_c_only = true, browser_analysis_target = handle },
            { target = "browser", emit_c_only = true },
            { target = "browser", emit_c_only = false, analysis_only = true, browser_analysis_target = handle },
            { target = "browser", emit_c_only = true, browser_analysis_target = handle, completion_closed_world = true },
            { target = "browser", emit_c_only = true, browser_analysis_target = handle, output_root = "/out" },
        }) do
            assert.has_error(function() driver.new_resolver_context(options) end)
        end
        local context = driver.new_resolver_context({ target = "browser", emit_c_only = true,
            browser_analysis_target = handle, io = compiler_io.new_memory() })
        assert.is_true(context.emit_c_only)
        assert.is_false(context.analysis_only)
        assert(driver.close_resolver_context(context))
    end)
end)

describe("playground compiler", function()
    local MAIN = 'local io = import "io"\nlocal moons = import "moons"\n\n' ..
        '--- How many moons Saturn has.\nfunction main(args: {string}): integer\n' ..
        '  io.print("Saturn has " .. moons.count() .. " moons")\n  return 0\nend\n'
    local MOONS = "function count(): integer\n  return 274\nend\n"
    local service, assets
    local saved_imported, saved_registry
    before_each(function() saved_imported, saved_registry = driver.imported, types.registry end)
    after_each(function() driver.imported, types.registry = saved_imported, saved_registry end)

    local function open()
        if not assets then
            local why
            assets, why = semantic_assets()
            if not assets then return nil, why end
        end
        service = service or assert(playground.open(assets))
        return service
    end

    it("checks every project module and reports project paths", function()
        local opened, why = open(); if not opened then pending(why); return end
        assert.same({}, service:check({ ["main.titan"] = MAIN, ["moons.titan"] = MOONS, ["bindings.js"] = "x" }))
        local diagnostics = service:check({ ["main.titan"] = MAIN, ["moons.titan"] = MOONS:gsub("274", '"many"') })
        assert.equal(1, #diagnostics)
        assert.same({ path = "moons.titan", line = 2, col = 10, severity = "error",
            message = "type error: types in return do not match, expected integer but found string" }, diagnostics[1])
        -- A removed module is gone in the next snapshot.
        local removed = service:check({ ["main.titan"] = MAIN })
        assert.equal("main.titan", removed[1].path)
        assert.matches("moons", removed[1].message)
        assert.has_error(function() service:check({ ["titan/json.titan"] = "" }) end)
        assert.has_error(function() service:check({ ["../main.titan"] = "" }) end)
    end)

    it("describes and completes names at byte offsets", function()
        local opened, why = open(); if not opened then pending(why); return end
        local project = { ["main.titan"] = MAIN, ["moons.titan"] = MOONS }
        local at = MAIN:find("count()", 1, true) - 1
        local hover = service:hover(project, { path = "main.titan", offset = at + 2 })
        assert.same({ path = "main.titan", from = at, to = at + 5 }, hover.at)
        assert.equal("count: function (): integer", hover.signature)
        local print_at = MAIN:find("print", 1, true) - 1
        hover = service:hover(project, { path = "main.titan", offset = print_at })
        assert.equal("print: function (...: value): ()", hover.signature)
        assert.truthy(hover.summary)
        local partial = MAIN:gsub("moons%.count%(%)", "moons.co()")
        local caret = partial:find("moons.co", 1, true) + 7
        local completion = service:complete({ ["main.titan"] = partial, ["moons.titan"] = MOONS },
            { path = "main.titan", offset = caret })
        assert.same({ path = "main.titan", from = caret - 2, to = caret }, completion.replace)
        assert.same({ label = "count", kind = "function", detail = "function (): integer" }, completion.items[1])
    end)

    it("selects logical modules as the target's source resolver does", function()
        local opened, why = open(); if not opened then pending(why); return end
        local project = {
            ["main.titan"] = 'local ink = import "ink"\nlocal deep = import "a.b"\nlocal v = import "v"\n' ..
                'function main(args: {string}): integer\n  return ink.digit() + deep.value() + v.n() - 13\nend\n',
            ["ink/ink.titan"] = "function digit(): integer\n  return seven()\nend\n",
            ["ink/digit.titan"] = "local function seven(): integer\n  return 7\nend\n",
            ["a/b/b.titan"] = "function value(): integer\n  return five()\nend\n",
            ["a/b/five.titan"] = "local function five(): integer\n  return 5\nend\n",
            ["v.titan"] = "this file is shadowed\n",
            ["v.browser.titan"] = "function n(): integer\n  return 1\nend\n",
            ["v.native.titan"] = "neither is this one\n",
            ["extra.native.titan"] = "not for the browser\n",
        }
        assert.same({}, service:check(project))
        local misspelled = service:check({ ["main.titan"] = MAIN, ["moons.titan"] = MOONS, ["x.Browser.titan"] = "" })
        assert.same({ { path = "x.Browser.titan", line = 1, col = 1, severity = "error",
            message = "mis-cased target label in source 'x.Browser.titan'" } }, misspelled)
        local contributor = project["ink/digit.titan"]
        local hover = service:hover(project, { path = "ink/digit.titan", offset = contributor:find("seven") })
        assert.equal("seven: function (): integer", hover.signature)
        assert.is_nil(service:hover(project, { path = "extra.native.titan", offset = 0 }))
        local edited = {}
        for name, contents in pairs(project) do edited[name] = contents end
        edited["ink/ink.titan"] = project["ink/ink.titan"]:gsub("seven%(%)", "sev()")
        local completed = service:complete(edited,
            { path = "ink/ink.titan", offset = edited["ink/ink.titan"]:find("sev", 1, true) + 2 })
        local labels = {}
        for _, item in ipairs(completed.items) do labels[item.label] = true end
        assert.is_true(labels.seven)
        local emitted = service:emit_c(project, string.rep("0", 64))
        assert.same({}, emitted.diagnostics)
        assert.same({ "a/b.c", "ink.c", "main.c", "v.c" }, emitted.units)
    end)

    it("completes the module names an import string can name", function()
        local opened, why = open(); if not opened then pending(why); return end
        local source = 'local j = import ""\nfunction main(args: {string}): integer\n  return 0\nend\n'
        local caret = source:find('""', 1, true)
        local project = { ["main.titan"] = source, ["moons.titan"] = MOONS, ["json.titan"] = MOONS,
            ["data/sets.titan"] = MOONS }
        local completed = service:complete(project, { path = "main.titan", offset = caret })
        assert.same({ path = "main.titan", from = caret, to = caret }, completed.replace)
        local labels = {}
        for _, item in ipairs(completed.items) do
            assert.equal("module", item.kind)
            labels[item.label] = item.detail
        end
        assert.equal("project module", labels.moons)
        assert.equal("project module source", labels["moons.titan"])
        assert.equal("project module", labels["data.sets"])
        assert.equal("standard library", labels.json)
        assert.equal("standard library", labels["titan.json"])
        assert.equal("standard library", labels.io)
        assert.equal("standard library", labels["titan.io"])
        -- A spelling the parser maps elsewhere, the cursor's own module and a
        -- module absent from the browser target are never offered.
        assert.is_nil(labels["json.titan"])
        assert.is_nil(labels["titan.json.titan"])
        assert.is_nil(labels.main)
        assert.is_nil(labels["main.titan"])
        assert.is_nil(labels.fs)
        assert.is_nil(labels["titan.fs"])
        for _, typed in ipairs({ "data.se", "titan.br" }) do
            local partial = 'local j = import "' .. typed .. '"\n'
            completed = service:complete({ ["main.titan"] = partial, ["data/sets.titan"] = MOONS },
                { path = "main.titan", offset = 18 + #typed })
            assert.same({ path = "main.titan", from = 18, to = 18 + #typed }, completed.replace)
            local offered = {}
            for _, item in ipairs(completed.items) do offered[item.label] = true end
            assert.is_true(offered[typed == "data.se" and "data.sets" or "titan.browser"])
            assert.is_true(offered.browser)
        end
    end)

    it("emits each module and the image entry without source records", function()
        local opened, why = open(); if not opened then pending(why); return end
        local identity = string.rep("0123456789abcdef", 4)
        local emitted = service:emit_c({ ["main.titan"] = MAIN, ["moons.titan"] = MOONS }, identity)
        assert.same({}, emitted.diagnostics)
        assert.same({ "main.c", "moons.c" }, emitted.units)
        assert.equal(".titan-links/main/synthetic/main__entrypoint.c", emitted.entry)
        for _, unit in ipairs(emitted.units) do
            local stem = unit:gsub("%.c$", "")
            assert.truthy(emitted.files[unit]:find('#include "' .. stem .. '.ffi.h"', 1, true))
            assert.truthy(emitted.files[stem .. ".ffi.h"])
            assert.is_nil(emitted.files[unit]:find("titan_source", 1, true))
            assert.truthy(emitted.files[unit]:find("titan_metadata", 1, true))
        end
        assert.truthy(emitted.files[emitted.entry]:find(identity, 1, true))
        local failed = service:emit_c({ ["main.titan"] = MAIN:gsub("return 0", 'return "zero"') }, identity)
        assert.same({}, failed.units)
        assert.equal("", failed.entry)
        assert.is_true(#failed.diagnostics > 0)
        -- No module stem can occupy the entry's directory.
        local colliding = service:emit_c({ ["main__entrypoint.titan"] = MOONS, ["main.titan"] =
            'local m = import "main__entrypoint"\nfunction main(args: {string}): integer\n  return m.count() - 274\nend\n' },
            identity)
        assert.same({}, colliding.diagnostics)
        assert.same({ "main.c", "main__entrypoint.c" }, colliding.units)
        assert.truthy(colliding.files["main__entrypoint.c"]:find("titan_metadata", 1, true))
        assert.truthy(colliding.files[colliding.entry]:find(identity, 1, true))
    end)

    it("emits pure explicit source imports across directories without a C toolchain", function()
        local opened, why = open(); if not opened then pending(why); return end
        local project = {
            ["main.titan"] = 'local u = import "nested.util.titan"\nfunction main(args: {string}): integer\n' ..
                "  return u.n() - 3\nend\n",
            ["nested/util.titan"] = 'local d = import "other.deep.titan"\nlocal function n(): integer\n' ..
                "  return d.k()\nend\n",
            ["other/deep.titan"] = "local function k(): integer\n  return 3\nend\n",
        }
        assert.same({}, service:check(project))
        local emitted = service:emit_c(project, string.rep("1", 64))
        assert.same({}, emitted.diagnostics)
        assert.same({ "main.c", "nested/util.c", "other/deep.c" }, emitted.units)
        assert.truthy(emitted.files["main.ffi.h"]:find('#include "nested/util.ffi.h"', 1, true))
        assert.truthy(emitted.files["nested/util.ffi.h"]:find('#include "../other/deep.ffi.h"', 1, true))
        assert.truthy(emitted.files["nested/util.c"]:find('#include "util.ffi.h"', 1, true))
    end)

    it("links emitted C into an image whose trace names the program's frames", function()
        local opened, why = open(); if not opened then pending(why); return end
        local info
        info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        local workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local identity = string.rep("fedcba9876543210", 4)
        local program = 'local io = import "io"\nlocal moons = import "moons"\nlocal fmt = import "lib.fmt.titan"\n\n' ..
            'function main(args: {string}): integer\n  if #args > 0 then raise "boom" end\n' ..
            '  io.print(fmt.line(moons.count()))\n  return 0\nend\n'
        local emitted = service:emit_c({ ["main.titan"] = program, ["moons.titan"] = MOONS, ["lib/fmt.titan"] =
            'local function line(count: integer): string\n  return "Saturn has " .. count .. " moons"\nend\n' },
            identity)
        assert.same({}, emitted.diagnostics)
        for name, contents in pairs(emitted.files) do files.write(path.join(workspace, name), contents) end
        local context = driver.new_resolver_context({ target = "browser" })
        local descriptor = assert(driver.context_target_descriptor(context))
        local plan = assert(driver.browserlink.profile(descriptor, { purpose = "program" }))
        local objects = {}
        for _, unit in ipairs({ emitted.entry, table.unpack(emitted.units) }) do
            local argv = driver._browser_target.compiler_argv(descriptor.tools)
            for _, flag in ipairs(descriptor.compile_flags) do argv[#argv + 1] = flag end
            for _, directory in ipairs(descriptor.include_dirs) do argv[#argv + 1] = "-I" .. directory end
            objects[#objects + 1] = unit:gsub("%.c$", ".o")
            for _, argument in ipairs({ "-c", unit, "-o", objects[#objects] }) do argv[#argv + 1] = argument end
            local ok, output = run(argv, workspace)
            assert.is_true(ok, output)
        end
        local link = driver._browser_target.compiler_argv(descriptor.tools)
        for _, flag in ipairs(plan.link_flags) do link[#link + 1] = flag end
        for _, argument in ipairs({ "-o", "app.linked.wasm", table.unpack(objects) }) do link[#link + 1] = argument end
        for _, archive in ipairs({ path.join(SDK, "titan.a"), path.join(SDK, "libtitan-lpeglabel.a"),
                descriptor.paths.libtitan, descriptor.paths.liblua }) do
            link[#link + 1] = archive
        end
        local ok, output = run(link, workspace)
        assert.is_true(ok, output)
        local optimize = { table.unpack(descriptor.tools.optimizer.argv) }
        for _, flag in ipairs(plan.optimizer_flags) do optimize[#optimize + 1] = flag end
        for _, argument in ipairs({ "app.linked.wasm", "-o", "app.optimized.wasm" }) do
            optimize[#optimize + 1] = argument
        end
        ok, output = run(optimize, workspace)
        assert.is_true(ok, output)
        assert(driver.close_resolver_context(context))
        local image = assert(playground.build_trace(read(path.join(workspace, "app.optimized.wasm")), identity,
            read(path.join(SDK, "titan-wasm-factory.mjs")), read(path.join(SDK, "titan-browser.mjs"))))
        assert.truthy(image.map:find('"./main.titan"', 1, true))
        for name, contents in pairs({ ["app.mjs"] = image.mjs, ["app.wasm"] = image.wasm,
                ["app.wasm.trace"] = image.trace, ["app.wasm.map"] = image.map }) do
            files.write(path.join(workspace, name), contents)
        end
        local runner = path.join(SDK, "titan-browser-run")
        ok, output = run({ runner, "--engine", "node", path.join(workspace, "app.mjs") })
        assert.is_true(ok, output)
        assert.equal("Saturn has 274 moons\n", output)
        ok, output = run({ runner, "--engine", "node", path.join(workspace, "app.mjs"), "--", "fail" })
        assert.is_false(ok)
        assert.truthy(output:find("boom", 1, true), output)
        assert.truthy(output:find("main.titan:6: in main.main", 1, true), output)
        files.remove(workspace)
    end)
end)

describe("titanc --no-source-records", function()
    local ROOT = assert(lfs.currentdir())

    local function titanc(directory, arguments)
        local argv = { "env", "-u", "MAKEFLAGS", "TITAN_ROOT=" .. PREFIX, "TITAN_EXTRA_CPPFLAGS=",
            "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=", path.join(PREFIX, "bin/lua"), "-e",
            "package.path = " .. string.format("%q", ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") ..
                " .. package.path", ROOT .. "/titanc", "-q" }
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        return run(argv, directory)
    end

    it("links objects whose records travel only through the coordinator", function()
        if platform.windows then pending("exercised on POSIX native targets"); return end
        local workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.write(path.join(workspace, "app.titan"), 'local util = import "util"\n' ..
            'function main(args: {string}): integer\n  if util.twice(21) == 42 then return 0 end\n  return 1\nend\n')
        files.write(path.join(workspace, "util.titan"), "function twice(x: integer): integer\n  return 2 * x\nend\n")
        local ok, output = titanc(workspace, { "--no-source-records", "-j2", "-o", "out", "app" })
        assert.is_true(ok, output)
        ok, output = run({ path.join(workspace, "out/app") })
        assert.is_true(ok, output)
        for _, name in ipairs({ "app", "util" }) do
            local object = read(path.join(workspace, "out/" .. name .. ".o"))
            assert.is_nil((staticmetadata.read_object_section(object, name, { elf = ".titan.source",
                coff = ".titan.source", wasm = ".titan.source", macho_segment = "__TEXT",
                macho_section = "__titansrc" }, #object)))
            assert.is_nil(read(path.join(workspace, "out/" .. name .. ".c")):find("titan_source", 1, true))
        end
        for _, conflicting in ipairs({ "--incremental", "-c" }) do
            ok, output = titanc(workspace, { "--no-source-records", conflicting, "-o", "out", "app" })
            assert.is_false(ok)
            assert.matches("%-%-no%-source%-records cannot be combined", output)
        end
        files.remove(workspace)
    end)
end)

describe("make playground-sdk directory ownership", function()
    local ROOT = assert(lfs.currentdir())

    -- The recipe refuses before it reads the SDK, so no browser SDK is needed.
    local function playground_sdk(build, out)
        return run({ "env", "PREFIX=" .. PREFIX, "TITAN_INSTALL_TREE=", path.join(PREFIX, "bin/lua"), "-E",
            path.join(ROOT, "scripts/playground_sdk.lua"), build, out, ROOT, "--runtime-source", "unused.c",
            "--lpeglabel-source", "unused.c", "titan.json" }, ROOT)
    end

    it("refuses directories it does not own before writing or removing anything", function()
        if platform.windows then pending("the recipe is POSIX make only"); return end
        -- Under the checkout's output tree, which lies outside every prefix.
        local scratch = temporary.name(); assert(os.remove(scratch))
        local workspace = path.join(ROOT, "out", path.basename(scratch)); files.mkdir(workspace)
        local foreign = path.join(workspace, "foreign")
        files.write(path.join(foreign, "provider/src/keep.txt"), "user data")
        local fresh_out = path.join(workspace, "out")
        local ok, output = playground_sdk(foreign, fresh_out)
        assert.is_false(ok)
        assert.matches("holds files playground%-sdk did not create", output)
        assert.equal("user data", read(path.join(foreign, "provider/src/keep.txt")))

        local inside_sources = path.join(ROOT, "titan/.playground-build-" .. tostring(os.time()))
        ok, output = playground_sdk(inside_sources, fresh_out)
        assert.is_false(ok)
        assert.matches("overlaps the library sources", output)
        assert.is_nil((strategy:stat(inside_sources)))

        local installed = driver.installed_paths(PREFIX, "browser").titan_bin
        ok, output = playground_sdk(path.join(workspace, "build"), installed)
        assert.is_false(ok)
        assert.matches("overlaps the installation", output)

        ok, output = playground_sdk(path.join(workspace, "same"), path.join(workspace, "same/bundle"))
        assert.is_false(ok)
        assert.matches("overlap", output)

        -- Bundle file names alone prove nothing: only the bundle marker does.
        local licensed = path.join(workspace, "licensed")
        files.write(path.join(licensed, "LICENSE"), "the user's own license")
        ok, output = playground_sdk(path.join(workspace, "build"), licensed)
        assert.is_false(ok)
        assert.matches("is not empty and is not an earlier playground bundle", output)
        assert.equal("the user's own license", read(path.join(licensed, "LICENSE")))

        local unrelated = path.join(workspace, "unrelated")
        files.write(path.join(unrelated, "notes.txt"), "user notes")
        files.write(path.join(unrelated, ".playground-bundle"), "")
        local linked = path.join(workspace, "linked")
        assert(lfs.link(unrelated, linked, true))
        ok, output = playground_sdk(path.join(workspace, "build"), linked)
        assert.is_false(ok)
        assert.matches("is a symbolic link", output)

        local marked = path.join(workspace, "marked")
        files.write(path.join(marked, ".playground-bundle"), "")
        files.write(path.join(marked, "titanc.wasm"), "old bundle")
        files.write(path.join(marked, "notes.txt"), "user notes")
        ok, output = playground_sdk(path.join(workspace, "build"), marked)
        assert.is_false(ok)
        assert.matches("holds 'notes.txt', which is not a bundle file", output)
        assert.equal("user notes", read(path.join(marked, "notes.txt")))
        assert.equal("old bundle", read(path.join(marked, "titanc.wasm")))
        assert.equal("user notes", read(path.join(unrelated, "notes.txt")))
        assert.is_nil((strategy:stat(path.join(workspace, "build"))))
        assert.is_nil((strategy:stat(fresh_out)))
        files.remove(workspace)
    end)
end)

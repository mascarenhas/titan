local assert = require "luassert"
local lfs = require "lfs"
local objectmetadata = require "titan-compiler.objectmetadata"
local staticmetadata = require "titan-compiler.staticmetadata"
local fixtures = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local types = require "titan-compiler.types"
local browserlink = require "titan-compiler.browserlink"
local driver = require "titan-compiler.driver"

local repository = assert(lfs.currentdir())
local modules = { "bundle.first", "bundle.second" }
local fixture, native_root, browser_root, provider_images
local semantic_driver, semantic_contexts, saved_registry

local function arguments(target, compile_only)
    local argv = { "--target", target, "--incremental", "--source-first",
        "--jobs", "1", "--c-parts", "1", "-v" }
    if compile_only then argv[#argv + 1] = "-c" end
    for _, name in ipairs(modules) do argv[#argv + 1] = name end
    return argv
end

local function compile(target, output, compile_only)
    fixture.output = output
    -- This target's compile flags are selected by the compiler, never copied
    -- from host CC/CFLAGS. The fixture helper otherwise uses native defaults.
    return fixture:compile(arguments(target, compile_only), {
        TITAN_EXTRA_CFLAGS = "-O0 -fno-lto", TITAN_EXTRA_LDFLAGS = "-fno-lto" })
end

local function compiled(target, output, compile_only)
    local result = compile(target, output, compile_only)
    assert.is_true(result.ok, result.output)
    return result.output
end

local function object_path(output, name)
    return output .. "/" .. name:gsub("%.", "/") .. ".o"
end

local function remember(output)
    local saved, past = {}, os.time() - 120
    for _, name in ipairs(modules) do
        local filename = object_path(output, name)
        assert(lfs.touch(filename, past, past))
        saved[name] = { filename = filename, bytes = fixtures.read(filename), time = past }
    end
    return saved
end

local function decisions(output, saved, edited)
    local seen = {}
    for line in output:gmatch("[^\n]+") do
        local status, name = line:match("^Titan object (%w+) ([^:]+):")
        if saved[name] then
            assert.is_nil(seen[name], line)
            seen[name] = status
        end
    end
    for name, old in pairs(saved) do
        assert.equal(name == edited and "miss" or "hit", seen[name], output)
        if name == edited then
            assert.not_equal(old.time, lfs.attributes(old.filename, "modification"), name)
        else
            assert.equal(old.time, lfs.attributes(old.filename, "modification"), name)
            assert.equal(old.bytes, fixtures.read(old.filename), name)
        end
    end
end

local function record_path(output)
    local directory = output .. "/.titan-links"
    local found
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." then
            local filename = directory .. "/" .. name .. "/record"
            if lfs.attributes(filename, "mode") == "file" then
                assert.is_nil(found, "unexpected second library link record")
                found = filename
            end
        end
    end
    return assert(found, "library did not publish a link record")
end

describe("browser incremental compilation", function()
    local function prepare_fixture()
        fixture = fixtures.new()
        fixtures.copy(repository .. "/spec/fixtures/browser_iso/bundle", fixture.source .. "/bundle")
        native_root, browser_root = fixture.root .. "/native-out", fixture.root .. "/browser-out"
    end
    after_each(function()
        for _, context in ipairs(semantic_contexts or {}) do
            assert(semantic_driver.close_resolver_context(context))
        end
        semantic_contexts, semantic_driver = nil, nil
        if saved_registry then types.registry, saved_registry = saved_registry, nil end
        local owned_fixture, images = fixture, provider_images
        fixture, provider_images = nil, nil
        if owned_fixture then owned_fixture:close(images) end
    end)

    it("certifies selected archive members and direct objects with parentheses in every path", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        fixture = fixtures.new()
        local directory = fixture.root .. "/native(dir)"
        local archive, member, direct = directory .. "/lib(helper).a",
            directory .. "/helper(part).o", directory .. "/direct(part).o"
        local helper, object = fixture.source .. "/helper.c", fixture.source .. "/direct.c"
        local prefix_source, prefix_object = fixture.source .. "/prefix.c", directory .. "/lib"
        fixtures.write(fixture.source .. "/punctuation.h", "int archive_answer(void);\nint object_answer(void);\n")
        fixtures.write(fixture.source .. "/pair_main.titan", [[
foreign import "punctuation.h"
function main(args: {string}): integer
    return ffi.archive_answer() + ffi.object_answer()
end
]])
        fixtures.write(helper, "int archive_answer(void) { return 0; }\n")
        fixtures.write(object, "int object_answer(void) { return 0; }\n")
        fixtures.write(prefix_source, "int unused_prefix_answer(void) { return 19; }\n")
        local function payload()
            local result = fixture:compile({ "-q", "--target", "browser", "-c", "--incremental",
                "--c-source", helper, "--c-source", object, "--c-source", prefix_source,
                "--print-c-objects", "pair_main" })
            assert.is_true(result.ok, result.output)
            local objects = {}
            for filename in result.output:gmatch("[^\r\n]+") do objects[#objects + 1] = filename end
            assert.equal(3, #objects, result.output)
            fixtures.copy(objects[1], member); fixtures.copy(objects[2], direct)
            fixtures.copy(objects[3], prefix_object)
            result = fixture:run({ info.tools.ar[1], "rcsD", archive, member })
            assert.is_true(result.ok, result.output)
        end
        payload()
        -- A known direct object is also a lexical prefix of the archive path.
        local arguments = { "--target", "browser", "--incremental", "-v", "pair_main",
            "-X", archive, direct, prefix_object }
        local result = fixture:compile(arguments)
        assert.is_true(result.ok, result.output)
        local record = record_path(fixture.output)
        local trace = fixtures.read(record:gsub("/record$", "/link.d"))
        assert.truthy(trace:find(archive .. "(helper(part).o)", 1, true), trace)
        assert.truthy(trace:find(direct, 1, true), trace)
        result = fixture:compile(arguments)
        assert.is_true(result.ok, result.output)
        assert.matches("Titan link hit", result.output, 1, true)
        local image = fixture.output .. "/pair_main.mjs"
        local ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", image })
        assert.is_true(ran.ok, ran.output)
        fixtures.write(helper, "int archive_answer(void) { return 7; }\n")
        payload()
        result = fixture:compile(arguments)
        assert.is_true(result.ok, result.output)
        assert.matches("Titan link miss", result.output, 1, true)
        assert.matches("Titan object hit pair_main", result.output, 1, true)
        ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", image })
        assert.is_false(ran.ok)
        assert.equal(7, ran.status)
    end)

    for _, failure in ipairs({ "trace", "record" }) do
        it("restores both predecessor image files after a " .. failure .. " certificate failure", function()
            local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
            fixture = fixtures.new()
            local source = fixture.source .. "/pair_main.titan"
            local arguments = { "--target", "browser", "--incremental", "-v", "pair_main" }
            fixtures.write(source, "function main(args: {string}): integer return 0 end\n")
            local result = fixture:compile(arguments)
            assert.is_true(result.ok, result.output)
            local mjs, wasm = fixture.output .. "/pair_main.mjs", fixture.output .. "/pair_main.wasm"
            local previous_mjs, previous_wasm = fixture.root .. "/before.mjs", fixture.root .. "/before.wasm"
            fixtures.copy(mjs, previous_mjs); fixtures.copy(wasm, previous_wasm)
            local record = record_path(fixture.output)
            fixtures.write(source, "function main(args: {string}): integer return 7 end\n")
            local hook, log = fixture.root .. "/certificate-fault.lua", fixture.root .. "/certificate-observation"
            fixtures.write(hook, string.format([[
local certificate = require "titan-compiler.linkcertificate"
local driver = require "titan-compiler.driver"
local util = require "titan-compiler.util"
driver.browser_link_options = { purpose = "program", assertions = 0 }
local commit = certificate.commit
function certificate.commit(context, ticket)
    assert(util.get_file_contents(%q, "rb") ~= util.get_file_contents(%q, "rb"), "new mjs was not published")
    assert(util.get_file_contents(%q, "rb") ~= util.get_file_contents(%q, "rb"), "new wasm was not published")
    local file = assert(io.open(%q, "wb"))
    assert(file:write("new pair observed\n")); assert(file:close())
    if %q == "trace" then
        assert(context.io:write_file(ticket.native_policy.dependency_file, "missing-archive(member).a\n"))
    else
        local write = context.io.write_file
        function context.io:write_file(filename, bytes)
            if filename == ticket.record then return nil, "injected browser certificate write failure" end
            return write(self, filename, bytes)
        end
    end
    return commit(context, ticket)
end
]], mjs, previous_mjs, wasm, previous_wasm, log, failure))
            local setup = string.format("package.path=%q..package.path;",
                fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
                fixture.collector:init_code() .. string.format("dofile(%q);", hook)
            local argv = { info.prefix .. "/bin/lua", "-E", "-e", setup, fixture.frontend .. "/titanc",
                "--tree", fixture.source, "--output", fixture.output }
            for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
            result = fixture:run(argv)
            fixture.collector:collect()
            assert.is_false(result.ok)
            assert.matches(failure == "trace" and "invalid Wasm linker input trace" or
                "injected browser certificate write failure", result.output, 1, true)
            assert.equal("new pair observed\n", fixtures.read(log))
            assert.equal(fixtures.read(previous_mjs), fixtures.read(mjs))
            assert.equal(fixtures.read(previous_wasm), fixtures.read(wasm))
            assert.is_nil(lfs.attributes(record))
            for name in lfs.dir(fixture.output) do
                assert.is_nil(name:find(".stage.tmp.", 1, true), name)
                assert.is_nil(name:find(".old.tmp.", 1, true), name)
            end
            local ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", mjs })
            assert.is_true(ran.ok, ran.output)
            result = fixture:compile(arguments)
            assert.is_true(result.ok, result.output)
            assert.matches("Titan link miss", result.output, 1, true)
            ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", mjs })
            assert.is_false(ran.ok)
            assert.equal(7, ran.status)
        end)
    end

    it("certifies both image files, invalidates every shared asset and rolls back a failed pair commit", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        fixture = fixtures.new()
        local root = fixture.root .. "/sdk"
        fixtures.mkdir(root .. "/lib")
        assert(lfs.link(info.prefix .. "/lib/browser", root .. "/lib/browser", true))
        assert(lfs.link(info.prefix .. "/include", root .. "/include", true))
        local assets = browserlink.sdk_assets(driver.installed_paths(root, "browser"))
        local installed = browserlink.sdk_assets(driver.installed_paths(info.prefix, "browser"))
        local keys = { "runtime", "js_library", "loader", "runner", "runner_module", "node_worker", "page" }
        for _, key in ipairs(keys) do fixtures.copy(installed[key], assets[key]) end
        fixtures.write(fixture.source .. "/pair_main.titan",
            "function main(args: {string}): integer return 0 end\n")
        local environment = { TITAN_ROOT = root }
        local arguments = { "--target", "browser", "--incremental", "-v", "pair_main" }
        local function build()
            local result = fixture:compile(arguments, environment)
            assert.is_true(result.ok, result.output)
            return result.output
        end
        assert.matches("Titan link miss", build(), 1, true)
        local mjs, wasm = fixture.output .. "/pair_main.mjs", fixture.output .. "/pair_main.wasm"
        local record = record_path(fixture.output)
        local original = { mjs = fixtures.read(mjs), wasm = fixtures.read(wasm), record = fixtures.read(record) }
        local past = os.time() - 120
        assert(lfs.touch(mjs, past, past)); assert(lfs.touch(wasm, past, past))
        assert.matches("Titan link hit", build(), 1, true)
        assert.equal(past, lfs.attributes(mjs, "modification"))
        assert.equal(past, lfs.attributes(wasm, "modification"))
        assert.equal(original.record, fixtures.read(record))
        for _, filename in ipairs({ mjs, wasm }) do
            fixtures.write(filename, fixtures.read(filename) .. "corrupt")
            local output = build()
            assert.matches("Titan link miss", output, 1, true)
            assert.matches("Titan object hit pair_main", output, 1, true)
            assert.equal(original.mjs, fixtures.read(mjs))
            assert.equal(original.wasm, fixtures.read(wasm))
        end
        for _, key in ipairs(keys) do
            local bytes = fixtures.read(assets[key])
            if key == "runtime" then
                -- A valid ar timestamp edit changes bytes without breaking objects.
                bytes = bytes:sub(1, 24) .. "2" .. bytes:sub(26)
            else
                bytes = bytes .. (key == "runner" and "\n# image asset invalidation\n" or "\n// image asset invalidation\n")
            end
            fixtures.write(assets[key], bytes)
            local output = build()
            assert.matches("Titan link miss", output, 1, true)
            assert.matches("Titan object hit pair_main", output, 1, true)
        end
        local predecessor = { mjs = fixtures.read(mjs), wasm = fixtures.read(wasm) }
        fixtures.write(fixture.source .. "/pair_main.titan",
            "function main(args: {string}): integer return 7 end\n")
        local log = fixture.root .. "/renames"
        local hook = fixture.root .. "/commit-fault.lua"
        fixtures.write(hook, string.format([[
local io_module = require "titan-compiler.io"
local original = io_module.new_sync
local mjs, wasm, log = %q, %q, %q
local failed
local function record(message)
    local file = assert(io.open(log, "ab"))
    assert(file:write(message, "\n")); assert(file:close())
end
function io_module.new_sync(...)
    local strategy = original(...)
    local rename = strategy.rename
    function strategy:rename(from, to)
        if from == wasm and to ~= wasm then record("backup") end
        if to == wasm then record("wasm") end
        if to == mjs and not failed then
            failed = true
            record("mjs-failed")
            return nil, "forced browser mjs commit failure"
        end
        return rename(self, from, to)
    end
    return strategy
end
]], mjs, wasm, log))
        local setup = string.format("package.path=%q..package.path;",
            fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
            fixture.collector:init_code() .. string.format("dofile(%q);", hook)
        local argv = { info.prefix .. "/bin/lua", "-E", "-e", setup, fixture.frontend .. "/titanc",
            "--tree", fixture.source, "--output", fixture.output }
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        local failed = fixture:run(argv, environment)
        fixture.collector:collect()
        assert.is_false(failed.ok)
        assert.matches("forced browser mjs commit failure", failed.output, 1, true)
        assert.equal("backup\nwasm\nmjs-failed\nwasm\n", fixtures.read(log))
        assert.equal(predecessor.mjs, fixtures.read(mjs))
        assert.equal(predecessor.wasm, fixtures.read(wasm))
        assert.is_nil(lfs.attributes(record), "failed pair cannot retain a link hit record")
        for name in lfs.dir(fixture.output) do
            assert.is_nil(name:find(".stage.tmp.", 1, true), name)
            assert.is_nil(name:find(".old.tmp.", 1, true), name)
        end
        local ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", mjs })
        assert.is_true(ran.ok, ran.output)
        assert.matches("Titan link miss", build(), 1, true)
        ran = fixture:run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", mjs })
        assert.is_false(ran.ok)
        assert.equal(7, ran.status)
    end)

    it("reuses warm browser objects and archives, recompiles only the edited variant, and leaves the native root unchanged", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare_fixture()
        compiled(fixture.host, native_root)
        local native = remember(native_root)
        local native_archive = fixtures.read(native_root .. "/bundle.a")
        local native_record = record_path(native_root)
        local native_record_bytes = fixtures.read(native_record)
        compiled("browser", browser_root)
        assert.equal("browser\n", fixtures.read(browser_root .. "/.titan-target"))
        assert.is_nil(lfs.attributes(native_root .. "/.titan-target"))
        assert.is_nil(lfs.attributes(browser_root .. "/bundle.so"))
        local browser = remember(browser_root)
        for _, name in ipairs(modules) do
            local bytes = fixtures.read(object_path(browser_root, name))
            local object = assert(staticmetadata.classify_object(bytes, name))
            assert.equal("wasm", object.format)
            local record = assert(objectmetadata.read(bytes, name))
            assert.is_string(record.object_metadata.certificate.configuration.toolchain)
            assert.not_equal(native[name].bytes, bytes)
        end
        local archive = fixtures.read(browser_root .. "/bundle.a")
        local link_record = record_path(browser_root)
        local record_bytes = fixtures.read(link_record)
        local warm = compiled("browser", browser_root)
        decisions(warm, browser)
        assert.matches("Titan link hit", warm, 1, true)
        assert.equal(archive, fixtures.read(browser_root .. "/bundle.a"))
        assert.equal(record_bytes, fixtures.read(link_record))
        fixtures.write(fixture.source .. "/bundle/first.browser.titan",
            "function answer(): integer\n    return 43\nend\n")
        local edited = compiled("browser", browser_root)
        decisions(edited, browser, "bundle.first")
        assert.not_equal(browser["bundle.first"].bytes,
            fixtures.read(object_path(browser_root, "bundle.first")))
        assert.matches("Titan link miss", edited, 1, true)
        local host_warm = compiled(fixture.host, native_root)
        decisions(host_warm, native)
        assert.matches("Titan link hit", host_warm, 1, true)
        assert.equal(native_archive, fixtures.read(native_root .. "/bundle.a"))
        assert.equal(native_record_bytes, fixtures.read(native_record))
    end)

    it("rejects transplanted foreign object and link certificates in both target directions", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare_fixture()
        compiled(fixture.host, native_root)
        compiled("browser", browser_root)
        local browser = remember(browser_root)
        local native_record = record_path(native_root)
        local browser_record = record_path(browser_root)
        fixtures.write(object_path(browser_root, "bundle.second"),
            fixtures.read(object_path(native_root, "bundle.second")))
        fixtures.write(browser_record, fixtures.read(native_record))
        local rebuilt = compiled("browser", browser_root)
        decisions(rebuilt, browser, "bundle.second")
        assert.matches("Titan link miss", rebuilt, 1, true)
        assert.not_equal(fixtures.read(native_record), fixtures.read(browser_record))
        local object = assert(staticmetadata.classify_object(
            fixtures.read(object_path(browser_root, "bundle.second")), "bundle.second"))
        assert.equal("wasm", object.format)
        local native = remember(native_root)
        fixtures.write(object_path(native_root, "bundle.second"),
            fixtures.read(object_path(browser_root, "bundle.second")))
        fixtures.write(native_record, fixtures.read(browser_record))
        local host_rebuilt = compiled(fixture.host, native_root)
        decisions(host_rebuilt, native, "bundle.second")
        assert.matches("Titan link miss", host_rebuilt, 1, true)
        local native_object = assert(staticmetadata.classify_object(
            fixtures.read(object_path(native_root, "bundle.second")), "bundle.second"))
        assert.not_equal("wasm", native_object.format)
    end)

    it("diagnoses missing output and refuses mixed-target roots in either direction, including source-adjacent domains", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare_fixture()
        local missing = fixture:compile({ "--target", "browser", "-c", "bundle.first" }, nil, true)
        assert.is_false(missing.ok)
        assert.matches("--target browser requires --output", missing.output, 1, true)
        compiled(fixture.host, native_root, true)
        local browser_into_host = compile("browser", native_root, true)
        assert.is_false(browser_into_host.ok)
        assert.matches("is not empty and has no .titan-target marker", browser_into_host.output, 1, true)
        compiled("browser", browser_root, true)
        local host_into_browser = compile(fixture.host, browser_root, true)
        assert.is_false(host_into_browser.ok)
        assert.matches('belongs to target "browser", not "' .. fixture.host .. '"', host_into_browser.output, 1, true)
        fixtures.write(fixture.source .. "/.titan-target", "browser\n")
        local adjacent = fixture:compile({ "--target", fixture.host, "-c", "bundle.first" }, nil, true)
        assert.is_false(adjacent.ok)
        assert.matches('belongs to target "browser", not "' .. fixture.host .. '"', adjacent.output, 1, true)
    end)

    it("switches native to a genuine browser descriptor and back without sharing source or warm native-provider state", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare_fixture()
        fixtures.write(fixture.source .. "/sequence.native.titan",
            "record Item\n native_value: integer\nend\n")
        fixtures.write(fixture.source .. "/sequence.browser.titan",
            "record Item\n browser_value: string\nend\n")
        fixtures.write(fixture.source .. "/warm/provider.titan",
            "function answer(): integer return 42 end\n")
        fixture:compiled({ "--jobs", "1", "--c-parts", "1", "warm.provider" })
        fixtures.write(fixture.source .. "/warm/provider.browser.titan",
            "function browser_only(): string return 'browser' end\n")
        local saved = package.loaded["titan-compiler.driver"]
        package.loaded["titan-compiler.driver"] = nil
        local ok, subject = pcall(require, "titan-compiler.driver")
        package.loaded["titan-compiler.driver"] = saved
        assert.is_true(ok, subject)
        semantic_driver, semantic_contexts, saved_registry = subject, {}, types.registry
        subject.TITAN_SOURCE_PATH = fixture.source
        subject.TITAN_BIN_PATH = fixture.output
        local function context(target, analysis_only)
            local value = subject.new_resolver_context({ target = target, analysis_only = analysis_only ~= false })
            semantic_contexts[#semantic_contexts + 1] = value
            return value
        end
        local function load(loader, name)
            local loaded, modtype, errors = loader(name)
            assert.is_true(loaded, modtype)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            return modtype
        end
        local native = context(nil, false)
        local native_loader = subject.defaultloader({}, { context = native, source_roots = { sequence = true } })
        load(native_loader, "sequence")
        local native_entry = subject.imported.sequence
        assert.is_table(native_entry.ast._erased_registry)
        local owner = types.registry["sequence.Item"]
        assert.is_table(owner)
        local provider = load(native_loader, "warm.provider")
        local native_provider = subject.imported["warm.provider"]
        provider_images = { native_provider.filename }
        assert.is_true(native_provider.kind == "dynamic" or native_provider.kind == "static")
        assert.equal(provider, load(native_loader, "warm.provider"))
        local browser = context("browser")
        assert.is_string(browser.target_descriptor.identity)
        assert.equal("6.0.13", browser.target_descriptor.tools.version)
        local native_path = subject.TITAN_BIN_PATH
        subject.TITAN_BIN_PATH = fixture.source
        local browser_loader = subject.defaultloader({}, { context = browser, source_roots = { sequence = true } })
        load(browser_loader, "sequence")
        assert.equal(fixture.source .. "/sequence.browser.titan", subject.imported.sequence.filename)
        assert.not_equal(owner, types.registry["sequence.Item"])
        load(browser_loader, "warm.provider")
        assert.equal("source", subject.imported["warm.provider"].kind)
        assert.has_error(function() native_loader("warm.provider") end,
            "compiler caches now belong to target " .. browser.target_descriptor.identity .. "; create a new context")
        local browser_registry, browser_imported = types.registry, subject.imported
        assert.has_error(function()
            subject.compile("sequence", native_entry.ast, native_entry.filename,
                {}, false, { context = native })
        end, "compiler caches now belong to target " .. browser.target_descriptor.identity .. "; create a new context")
        assert.equal(browser_registry, types.registry)
        assert.equal(browser_imported, subject.imported)
        assert.is_table(types.registry["sequence.Item"])
        assert(subject.assert_target_context(browser))
        subject.TITAN_BIN_PATH = native_path
        local final = context()
        local final_loader = subject.defaultloader({}, { context = final, source_roots = { sequence = true } })
        load(final_loader, "sequence")
        assert.equal(fixture.source .. "/sequence.native.titan", subject.imported.sequence.filename)
        load(final_loader, "warm.provider")
        assert.equal(native_provider.kind, subject.imported["warm.provider"].kind)
        assert.equal(native_provider.filename, subject.imported["warm.provider"].filename)
        assert.not_equal(native_provider, subject.imported["warm.provider"])
    end)
end)

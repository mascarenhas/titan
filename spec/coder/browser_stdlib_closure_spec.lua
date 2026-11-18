local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local temporary = require "spec.support.temporary"
local files = require "spec.fixtures.target_selection.support"
local strategy = require("titan-compiler.io").new_sync()
local checks = dofile("scripts/browser_stdlib.lua")
local certificate = require "titan-compiler.linkcertificate"
local native = require "titan-compiler.nativeinputs"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"
local driver = require "titan-compiler.driver"
local paths = require "titan-compiler.path"

describe("browser stdlib real-toolchain closure", function()
    local workspace
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)

    local function fixture(requirements)
        local info, why = toolchain.require(requirements or { node = true, sdk = true })
        if not info then pending(why); return end
        workspace = temporary.name("-browser-stdlib-closure")
        os.remove(workspace)
        files.mkdir(workspace)
        workspace = assert(strategy:realpath(workspace))
        return info
    end

    local function write(name, text) assert(strategy:write_file(workspace .. "/" .. name, text)) end
    local function run(argv)
        local result = strategy:run(argv, { stderr_to_stdout = true })
        assert.is_true(result.ok, result.output)
        return result.output
    end
    local function closure(info, output, source_tree)
        local argv = { info.prefix .. "/bin/lua", "-E", "scripts/check_browser_stdlib.lua", "closure",
            output, info.sdk_root .. "/titan.a", output .. "/intruder.wasm" }
        if source_tree then argv[#argv + 1] = source_tree end
        return strategy:run(argv, { stderr_to_stdout = true })
    end

    local function compile(info, output, extra)
        local argv = { info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", output, "--exe", output .. "/intruder.mjs", "intruder" }
        for _, argument in ipairs(extra or {}) do argv[#argv + 1] = argument end
        run(argv)
        assert(checks.check_image(assert(strategy:read_file(output .. "/intruder.wasm")), "intruder.wasm"))
    end

    it("rejects imported filesystem functions without rejecting native definitions or nonfunctions", function()
        local function section(id, bytes)
            assert.is_true(#bytes < 128)
            return string.char(id, #bytes) .. bytes
        end
        for _, name in ipairs({ "__syscall_closure_intruder", "fd_closure_intruder", "_emscripten_system" }) do
            for _, kind in ipairs({ 0, 3 }) do
                local import = "\1\3env" .. string.char(#name) .. name .. string.char(kind) ..
                    (kind == 0 and "\0" or "\127\0")
                local names = "\1\0\14portable_entry"
                local image = "\0asm\1\0\0\0" .. section(1, "\1\96\0\0") ..
                    section(2, import) .. section(3, "\1\0") .. section(10, "\1\2\0\11") ..
                    section(0, "\4name" .. section(1, kind == 0 and "\1\1\14portable_entry" or names))
                local ok, err = checks.check_image(image, "intruder.wasm")
                if kind == 0 then
                    assert.is_nil(ok)
                    assert.equal("intruder.wasm: forbidden browser filesystem import " .. name, err)
                else
                    assert.is_true(ok, err)
                end
            end
        end
    end)

    it("builds and audits the real suite target from cold and warm output trees", function()
        local info = fixture({ node = true, chrome = true, sdk = true })
        if not info then return end
        local output = workspace .. "/suite"
        assert.is_nil(strategy:lstat(output))
        -- The smallest real owner exercises the same plan, compiler, closure
        -- audits and two engines without relinking the entire stdlib suite.
        local argv = {
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
            "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
            toolchain.make, "--no-print-directory", "-f", toolchain.makefile,
            "titan-stdlib-browser-test",
            "PREFIX=" .. info.prefix, "TITAN_BROWSER_TEST_BUILD_DIR=" .. output,
            "TITAN_STDLIB_BROWSER_TEST_ROOTS=test.tests",
            "TITAN_FILTER=",
        }
        for _, state in ipairs({ "cold", "warm" }) do
            local log = run(argv)
            for _, engine in ipairs({ "node", "chromium" }) do
                assert.truthy(log:find("Browser stdlib engine: " .. engine .. " image: stdlib", 1, true), log)
            end
            local summaries = 0
            for _ in log:gmatch(
                    "Browser stdlib gate: selected=1 passed=1 skipped=0 failed=0 owners=1/1 images=1%.") do
                summaries = summaries + 1
            end
            assert.equal(2, summaries, state .. "\n" .. log)
            assert.equal("browser\n", assert(strategy:read_file(output .. "/objects/.titan-target")))
            assert.is_nil(strategy:lstat(output .. "/.titan-target"))
            assert.equal("test.tests\n", assert(strategy:read_file(output .. "/roots.txt")):gsub("\r\n", "\n"))
            assert.is_nil(strategy:lstat(output .. "/stdlib.roots.txt"))
            for _, artifact in ipairs({
                "images/stdlib.mjs", "images/stdlib.wasm", "images/stdlib.wasm.map", "images/stdlib.wasm.trace",
                "members.md",
                "stdlib.node.log", "stdlib.node.stderr.log", "stdlib.chromium.log", "stdlib.chromium.stderr.log",
            }) do
                assert.equal("file", assert(strategy:stat(output .. "/" .. artifact)).kind, artifact)
            end
        end
        argv[#argv] = "TITAN_FILTER=^test[.]tests[.]"
        local filtered = run(argv)
        assert.truthy(filtered:find("owners=1/1 images=1 (filtered)", 1, true), filtered)
        argv[#argv] = "TITAN_FILTER=^__no_case__$"
        local empty = strategy:run(argv, { stderr_to_stdout = true })
        assert.is_false(empty.ok, empty.output)
        assert.truthy(empty.output:find("selected no cases", 1, true), empty.output)
    end)

    it("rejects every absent standard module at compile time with the SDK's reason", function()
        local info = fixture({ sdk = true })
        if not info then return end
        for _, row in ipairs(checks.status_inventory.modules) do
            if row[2] == "absent" then
                local module = row[1]
                local name = "missing_" .. module:sub(7)
                write(name .. ".titan", "local missing = import " .. string.format("%q", module:sub(7)) .. "\n")
                local result = strategy:run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser",
                    "--tree", workspace, "--output", workspace .. "/missing-out", name },
                    { stderr_to_stdout = true })
                assert.is_true(result.started, result.output)
                assert.is_false(result.ok, result.output)
                assert.truthy(result.output:find("module '" .. module .. "' is not available for target 'browser': " ..
                    row.reason, 1, true), result.output)
            end
        end
    end)

    it("checks real-tree sources and rejects injected absent imports through the closure command", function()
        local info = fixture({ sdk = true })
        if not info then return end
        write("intruder.titan", "function main(_: {string}): integer return 0 end\n")
        local output = workspace .. "/source-out"
        compile(info, output)
        local control = closure(info, output)
        assert.is_true(control.ok, control.output)
        files.mkdir(workspace .. "/titan")
        for _, module in ipairs(checks.absent_modules) do
            write("titan/source_intruder.browser.titan",
                "local missing = import " .. string.format("%q", module:sub(7)) .. "\n")
            local result = closure(info, output, workspace)
            assert.is_true(result.started, result.output)
            assert.is_false(result.ok, result.output)
            assert.truthy(result.output:find(module, 1, true), result.output)
        end
    end)

    it("keeps absent modules out of SDK objects and archives even with neutral member names", function()
        local info = fixture({ sdk = true })
        if not info then return end
        assert(checks.check_archive(info.sdk_root .. "/titan.a"))
        files.mkdir(workspace .. "/titan")
        local argv = { info.prefix .. "/bin/titanc", "-q", "--target", "browser",
            "--tree", workspace, "--output", workspace .. "/absent-out" }
        local wanted = {}
        for _, module in ipairs(checks.absent_modules) do
            write("titan/" .. module:sub(7) .. ".titan", "function marker(): integer return 7 end\n")
            argv[#argv + 1] = module
            wanted[module] = true
        end
        run(argv)
        local archive = workspace .. "/absent-out/titan.a"
        local metadata = require "titan-compiler.staticmetadata"
        local scanned = assert(metadata.scan_archive(archive))
        local ok, err = checks.check_archive(archive, scanned)
        assert.is_nil(ok)
        assert.truthy(err:find("forbidden browser stdlib module", 1, true), err)
        local found = {}
        for _, member in ipairs(scanned.members) do
            local module = member.object.metadata and member.object.metadata.module
            if wanted[module] then
                found[module] = true
                local objects = workspace .. "/objects-" .. module:sub(7)
                files.mkdir(objects)
                local object = objects .. "/neutral.o"
                assert(strategy:write_file(object, member.bytes))
                ok, err = checks.check_output(strategy, objects)
                assert.is_nil(ok)
                assert.truthy(err:find(module, 1, true), err)
                local neutral = workspace .. "/neutral-" .. module:sub(7) .. ".a"
                run({ info.tools.ar[1], "rcs", neutral, object })
                ok, err = checks.check_archive(neutral)
                assert.is_nil(ok)
                assert.truthy(err:find(module, 1, true), err)
            end
        end
        assert.same(wanted, found)
    end)

    it("rejects a certified injected libuv header, an archive payload and an authored-C output symbol", function()
        local info, why = toolchain.require({ node = true, sdk = true })
        if not info then pending(why); return end
        workspace = temporary.name("-browser-stdlib-closure")
        os.remove(workspace)
        files.mkdir(workspace)
        workspace = assert(strategy:realpath(workspace))
        local function write(name, text) assert(strategy:write_file(workspace .. "/" .. name, text)) end
        local function run(argv)
            local result = strategy:run(argv, { stderr_to_stdout = true })
            assert.is_true(result.ok, result.output)
            return result.output
        end
        write("uv.h", "#define CLOSURE_INJECTED_VALUE 7\n")
        write("header_intruder.titan", [[
foreign import "uv.h"
function value(): integer
    return ffi.CLOSURE_INJECTED_VALUE
end
]])
        run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", workspace .. "/header-out", "header_intruder" })
        local ok, err = checks.check_archive(workspace .. "/header-out/header_intruder.a")
        assert.is_nil(ok)
        assert.truthy(err:find("uv.h", 1, true), err)
        assert.truthy(err:find("forbidden browser stdlib dependency", 1, true), err)

        write("raw.c", "int uv_closure_intruder(void) { return 0; }\n")
        write("raw.h", "int uv_closure_intruder(void);\n")
        run({ info.tools.cc[1], "-c", workspace .. "/raw.c", "-o", workspace .. "/raw.o" })
        run({ info.tools.ar[1], "rcs", workspace .. "/libuv.a", workspace .. "/raw.o" })
        ok, err = checks.check_archive(workspace .. "/libuv.a")
        assert.is_nil(ok)
        assert.truthy(err:find("forbidden browser stdlib dependency", 1, true), err)
        -- An innocuous archive name must not hide its defined native symbols.
        run({ info.tools.ar[1], "rcs", workspace .. "/payload.a", workspace .. "/raw.o" })
        ok, err = checks.check_archive(workspace .. "/payload.a")
        assert.is_nil(ok)
        assert.truthy(err:find("uv_closure_intruder", 1, true), err)

        write("image_intruder.titan", [[
foreign import "raw.h"
function main(_args: {string}): integer
    return ffi.uv_closure_intruder()
end
]])
        run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", workspace .. "/image-out", "--exe", workspace .. "/image-out/intruder.mjs",
            "--c-source", workspace .. "/raw.c", "image_intruder" })
        ok, err = checks.check_output(strategy, workspace .. "/image-out")
        assert.is_nil(ok)
        assert.truthy(err:find("uv_closure_intruder", 1, true), err)

        -- A named forbidden archive is rejected even when its selected object
        -- has no forbidden symbol. The linker certificate retains its path.
        write("portable.c", "int portable_payload(void) { return 0; }\n")
        write("portable.h", "int portable_payload(void);\n")
        run({ info.tools.cc[1], "-c", workspace .. "/portable.c", "-o", workspace .. "/portable.o" })
        run({ info.tools.ar[1], "rcs", workspace .. "/libuv_a.a", workspace .. "/portable.o" })
        write("archive_intruder.titan", [[
foreign import "portable.h"
function main(_args: {string}): integer
    return ffi.portable_payload()
end
]])
        run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", workspace .. "/archive-out", "--exe", workspace .. "/archive-out/intruder.mjs",
            "archive_intruder", "-X", workspace .. "/libuv_a.a" })
        assert(checks.check_image(assert(strategy:read_file(workspace .. "/archive-out/intruder.wasm")), "archive.wasm"))
        ok, err = checks.check_output(strategy, workspace .. "/archive-out")
        assert.is_nil(ok)
        assert.truthy(err:find("libuv_a.a", 1, true), err)
    end)

    it("audits authored-C macro-only headers on misses, hits and uncacheable builds, failing closed on missing evidence", function()
        local info = fixture()
        if not info then return end
        write("portable.h", "int portable_payload(void);\n")
        write("uv.h", "#define CLOSURE_INJECTED_VALUE 7\n")
        write("raw.c", '#include "uv.h"\nint portable_payload(void) { return CLOSURE_INJECTED_VALUE; }\n')
        write("opaque.rsp", "-DCLOSURE_OPAQUE=1\n")
        write("intruder.titan", [[
foreign import "portable.h"
function main(_args: {string}): integer
    return ffi.portable_payload()
end
]])
        for _, mode in ipairs({ "miss", "hit", "uncacheable" }) do
            local output = workspace .. "/" .. mode
            local arguments = { "--c-source", workspace .. "/raw.c" }
            if mode == "uncacheable" then
                -- The foreign-type frontend deliberately refuses opaque
                -- response files. Exercise the actual native compiler API
                -- with one, then link its uncacheable output into the image.
                run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
                    "--tree", workspace, "--output", output, "-c", "intruder" })
                local objects = assert(native.compile({ io = strategy }, {
                    sources = { workspace .. "/raw.c" }, output_root = output,
                    compile_argv = { info.tools.cc[1], "@" .. workspace .. "/opaque.rsp" },
                    uncacheable = "opaque compiler response file",
                }))
                assert.is_false(objects[1].cacheable)
                arguments = { "-X", objects[1].path }
            end
            compile(info, output, arguments)
            if mode == "hit" then compile(info, output, arguments) end
            local result = closure(info, output)
            assert.is_false(result.ok, result.output)
            assert.truthy(result.output:find("forbidden browser stdlib dependency", 1, true), result.output)
            assert.truthy(result.output:find("uv.h", 1, true), result.output)
            local inventory = assert(certificate.read_record({ io = strategy }, output .. "/.native/inputs"))
            assert.equal(1, #inventory.inputs)
            local object = inventory.inputs[1]
            if mode == "uncacheable" then
                assert.is_nil(strategy:stat((object:gsub("%.o$", ".record"))))
            end
            assert(strategy:unlink((object:gsub("%.o$", ".d"))))
            result = closure(info, output)
            assert.is_false(result.ok, result.output)
            assert.truthy(result.output:find("missing authored-C header provenance", 1, true), result.output)
        end

        -- A clean rebuild regenerates the evidence even after it was removed.
        write("raw.c", "int portable_payload(void) { return 0; }\n")
        local output = workspace .. "/miss"
        compile(info, output, { "--c-source", workspace .. "/raw.c" })
        local inventory = assert(certificate.read_record({ io = strategy }, output .. "/.native/inputs"))
        -- A warm output tree may also contain unused native cache nodes from
        -- older invocations, without dependency evidence from the new producer.
        assert(strategy:write_file(output .. "/.native/unused.o",
            assert(strategy:read_file(inventory.inputs[1]))))
        local result = closure(info, output)
        assert.is_true(result.ok, result.output)
        assert(strategy:unlink(output .. "/.native/inputs"))
        result = closure(info, output)
        assert.is_false(result.ok, result.output)
    end)

    for _, extension in ipairs({ "o", "a" }) do
        for _, undefined in ipairs({ false, true }) do
            it("inspects external " .. extension .. " inputs for " .. (undefined and "undefined" or "defined") ..
                " denied data, without confusing same-name physical inputs", function()
                local info = fixture()
                if not info then return end
                files.mkdir(workspace .. "/left")
                files.mkdir(workspace .. "/right")
                write("portable.h", "int portable_clean(void);\nint portable_payload(void);\n")
                write("left/payload.c", "int portable_clean(void) { return 0; }\n")
                write("right/payload.c", (undefined and
                    "extern volatile int uv_closure_data __attribute__((weak));\n" or
                    "volatile int uv_closure_data = 7;\n") ..
                    "int portable_payload(void) { " ..
                    (undefined and "return &uv_closure_data ? uv_closure_data : 0;" or "return uv_closure_data;") .. " }\n")
                write("intruder.titan", [[
foreign import "portable.h"
function main(_args: {string}): integer
    return ffi.portable_clean() + ffi.portable_payload()
end
]])
                local payloads = { "-X" }
                for _, side in ipairs({ "left", "right" }) do
                    local base = workspace .. "/" .. side .. "/payload"
                    run({ info.tools.cc[1], "-c", base .. ".c", "-o", base .. ".o" })
                    if extension == "a" then run({ info.tools.ar[1], "rcs", base .. ".a", base .. ".o" }) end
                    payloads[#payloads + 1] = base .. "." .. extension
                end
                local output = workspace .. "/out"
                compile(info, output, payloads)
                local result = closure(info, output)
                assert.is_false(result.ok, result.output)
                assert.truthy(result.output:find("uv_closure_data", 1, true), result.output)
                assert.truthy(result.output:find("/right/payload." .. extension, 1, true), result.output)

                -- Opaque third-party prebuilt inputs do not acquire a new
                -- universal header-metadata contract.
                write("right/payload.c", "int portable_payload(void) { return 0; }\n")
                run({ info.tools.cc[1], "-c", workspace .. "/right/payload.c", "-o", workspace .. "/right/payload.o" })
                if extension == "a" then
                    run({ info.tools.ar[1], "rcs", workspace .. "/right/payload.a", workspace .. "/right/payload.o" })
                end
                compile(info, output, payloads)
                result = closure(info, output)
                assert.is_true(result.ok, result.output)

                -- A second certified image references hard-link aliases, not
                -- just repeated path strings. Each physical payload is decoded
                -- once across both certificates and the output-tree traversal.
                local aliases, foreign = { "-X" }, {}
                local function path_key(path)
                    return platform.windows and paths.to_slash(path):lower() or path
                end
                for _, side in ipairs({ "left", "right" }) do
                    local original = workspace .. "/" .. side .. "/payload." .. extension
                    local alias = workspace .. "/mirror-" .. side .. "." .. extension
                    assert(lfs.link(original, alias))
                    aliases[#aliases + 1] = alias
                    foreign[path_key(original)], foreign[path_key(alias)] = true, true
                end
                run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
                    "--tree", workspace, "--output", output, "--exe", output .. "/mirror.mjs", "intruder",
                    table.unpack(aliases) })
                local reads = 0
                local observed = setmetatable({
                    read_file = function(_, filename, ...)
                        if foreign[path_key(filename)] then reads = reads + 1 end
                        return strategy:read_file(filename, ...)
                    end,
                }, { __index = function(_, method)
                    return function(_, ...) return strategy[method](strategy, ...) end
                end })
                assert(checks.check_output(observed, output))
                assert.equal(2, reads, "repeated physical native inputs were decoded again")
            end)
        end
    end

    -- Browser ExternalWait is opaque, so only its private field keeps a record
    -- literal of it rejected outside titan.async, as natively.
    it("rejects an ExternalWait record literal on the native and browser targets", function()
        local info = fixture()
        if not info then return end
        write("external_literal.titan", 'local async = import "async"\nlocal wait: async.ExternalWait = {}\n')
        for _, target in ipairs({ "native", "browser" }) do
            local argv = { info.prefix .. "/bin/titanc", "-q", "--tree", workspace,
                "--output", workspace .. "/" .. target, "-c", "external_literal" }
            if target == "browser" then
                argv[#argv + 1] = "--target"
                argv[#argv + 1] = "browser"
            end
            local result = strategy:run(argv, { stderr_to_stdout = true })
            assert.is_false(result.ok, target .. "\n" .. result.output)
            assert.truthy(result.output:find("cannot construct record type 'titan.async.ExternalWait' outside " ..
                "module 'titan.async' because it has local fields", 1, true), target .. "\n" .. result.output)
        end
    end)

    it("pins the browser type fixture to the installed provider", function()
        local info = fixture({ sdk = true })
        if not info then return end
        local browser = assert(staticmetadata.scan_archive(info.sdk_root .. "/titan.a"))
        assert.equal(assert(strategy:read_file("spec/fixtures/stdlib/titan_stdlib_browser_types.lua")),
            checks.type_fixture(browser),
            "browser type fixture is stale; regenerate it with check_browser_stdlib.lua fixture")
        -- Exercise the Windows oracle on Unix too, without replacing the
        -- separate comparison against Unix's installed native archive.
        local native = checks.native_fixture()
        assert(checks.inventory(native, browser))
        assert(checks.check_status(native, browser))
    end)

    it("pins the native type fixture to the installed archive", function()
        if platform.windows then
            pending("platform: Windows installs the native stdlib as a DLL, not a Titan archive")
            return
        end
        local info = fixture({ sdk = true })
        if not info then return end
        local native_provider = assert(driver.installed_paths(info.prefix)).titan_bin .. "/titan.a"
        local scanned = assert(staticmetadata.scan_archive(native_provider))
        local expected = checks.native_fixture()
        assert.equal(#expected.key_order, #scanned.key_order)
        for _, modname in ipairs(scanned.key_order) do
            assert.equal(expected.entries[modname].types, scanned.entries[modname].types, modname)
        end
    end)
end)

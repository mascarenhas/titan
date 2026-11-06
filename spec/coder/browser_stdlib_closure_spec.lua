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
    local function closure(info, output)
        return strategy:run({ info.prefix .. "/bin/lua", "-E", "scripts/check_browser_stdlib.lua", "closure",
            output, info.sdk_root .. "/titan.a", output .. "/intruder.wasm" }, { stderr_to_stdout = true })
    end

    local function compile(info, output, extra)
        local argv = { info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", output, "--exe", output .. "/intruder.mjs", "intruder" }
        for _, argument in ipairs(extra or {}) do argv[#argv + 1] = argument end
        run(argv)
        assert(checks.check_image(assert(strategy:read_file(output .. "/intruder.wasm")), "intruder.wasm"))
    end

    it("builds and audits the real suite target from cold and warm output trees", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        local info = fixture({ node = true, chrome = true, sdk = true })
        if not info then return end
        local output = workspace .. "/suite"
        assert.is_nil(strategy:lstat(output))
        -- The smallest real owner exercises the same plan, compiler, closure
        -- audits and two engines without relinking the entire stdlib suite.
        local argv = {
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
            "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
            "make", "--no-print-directory", "titan-stdlib-browser-test",
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
            assert.equal("test.tests\n", assert(strategy:read_file(output .. "/roots.txt")))
            assert.is_nil(strategy:lstat(output .. "/stdlib.roots.txt"))
            for _, artifact in ipairs({
                "images/stdlib.mjs", "images/stdlib.wasm", "images/stdlib.wasm.map", "members.md",
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

    it("rejects a certified injected libuv header, an archive payload and an internal image symbol", function()
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

        write("raw.c", "__attribute__((noinline)) int uv_closure_intruder(void) { return 0; }\n")
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
        ok, err = checks.check_image(assert(strategy:read_file(workspace .. "/image-out/intruder.wasm")), "intruder.wasm")
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
                for _, side in ipairs({ "left", "right" }) do
                    local original = workspace .. "/" .. side .. "/payload." .. extension
                    local alias = workspace .. "/mirror-" .. side .. "." .. extension
                    assert(lfs.link(original, alias))
                    aliases[#aliases + 1] = alias
                    foreign[original], foreign[alias] = true, true
                end
                run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
                    "--tree", workspace, "--output", output, "--exe", output .. "/mirror.mjs", "intruder",
                    table.unpack(aliases) })
                local reads = 0
                local observed = setmetatable({
                    read_file = function(_, filename, ...)
                        if foreign[filename] then reads = reads + 1 end
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
end)

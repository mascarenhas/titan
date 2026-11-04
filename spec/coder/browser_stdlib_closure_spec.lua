local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local temporary = require "spec.support.temporary"
local files = require "spec.fixtures.target_selection.support"
local strategy = require("titan-compiler.io").new_sync()
local checks = dofile("scripts/browser_stdlib.lua")

describe("browser stdlib real-toolchain closure", function()
    local workspace
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
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
        run({ info.tools.ar[1], "rcs", workspace .. "/libuv.a", workspace .. "/portable.o" })
        write("archive_intruder.titan", [[
foreign import "portable.h"
function main(_args: {string}): integer
    return ffi.portable_payload()
end
]])
        run({ info.prefix .. "/bin/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", workspace, "--output", workspace .. "/archive-out", "--exe", workspace .. "/archive-out/intruder.mjs",
            "archive_intruder", "-X", workspace .. "/libuv.a" })
        assert(checks.check_image(assert(strategy:read_file(workspace .. "/archive-out/intruder.wasm")), "archive.wasm"))
        ok, err = checks.check_output(strategy, workspace .. "/archive-out")
        assert.is_nil(ok)
        assert.truthy(err:find("libuv.a", 1, true), err)
    end)
end)

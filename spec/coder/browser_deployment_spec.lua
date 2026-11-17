local assert = require "luassert"
local lfs = require "lfs"
local files = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local repository = assert(lfs.currentdir())
local fixture

local function dependencies()
    for _, name in ipairs({ "TITAN_VITE_ROOT", "TITAN_PLAYWRIGHT_ROOT" }) do
        if not os.getenv(name) or os.getenv(name) == "" then
            local reason = "browser deployment requires " .. name
            if os.getenv("TITAN_REQUIRE_BROWSER_DEPLOYMENT") == "1" then error(reason) end
            return nil, reason
        end
    end
    return toolchain.require({ node = true, sdk = true })
end

describe("self-contained browser deployment", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    it("executes trace-ready generated assets over HTTP, locateFile relocation, and Vite", function()
        local info, why = dependencies()
        if not info then pending(why) return end
        fixture = files.new() -- Includes the ordinary compiler child-coverage collector.
        files.write(fixture.source .. "/deployment.titan", [[
foreign import "stdio.h"
function main(args: {string}): integer
  ffi.puts("deployment-ready")
  return 7
end
]])
        local image = fixture.output .. "/deployment.mjs"
        local built = fixture:compile({ "-q", "--target", "browser", "--incremental",
            "--no-uv-bootstrap", "--exe", image, "deployment" }, {
                TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
        assert.is_true(built.ok, built.output)
        toolchain.check_imports(image, { "entry" })
        for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.map", ".wasm.trace" }) do
            assert.equal("file", lfs.attributes(fixture.output .. "/deployment" .. suffix, "mode"))
        end
        local result = fixture:run({ info.node.path,
            repository .. "/spec/fixtures/browser_bridge/deployment.mjs", image }, {
                TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "",
                TITAN_VITE_ROOT = os.getenv("TITAN_VITE_ROOT"),
                TITAN_PLAYWRIGHT_ROOT = os.getenv("TITAN_PLAYWRIGHT_ROOT"),
            })
        io.stdout:write("\nBROWSER-DEPLOYMENT ", result.output, "\n")
        io.stdout:flush()
        assert.is_true(result.ok, result.output)
        assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
        assert.truthy(result.output:find('"pages":3', 1, true), result.output)
        assert.truthy(result.output:find('"vite":"8.3.6"', 1, true), result.output)
        assert.truthy(result.output:find('"nodeDefault":true', 1, true), result.output)
    end)
end)

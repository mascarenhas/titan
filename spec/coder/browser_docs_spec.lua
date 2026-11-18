-- The browser chapter's examples and the development server they use. The
-- server is a native program on titan.http, so this file is listed in
-- spec/support/ci_stdlib_compiler_test_files.txt and CI runs it after the
-- standard library is installed (native-coverage); the browser case also
-- needs the toolchain, Playwright and Vite, which only the chromium
-- Playwright cells supply and require.
local assert = require "luassert"
local lfs = require "lfs"
local files = require "spec.fixtures.target_selection.support"
local platform = require "titan-compiler.platform"
local toolchain = require "spec.support.browser_toolchain"
local repository = assert(lfs.currentdir())
local doc_check = dofile(repository .. "/scripts/doc_check.lua")
local fixture

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("a")); file:close()
    return text
end

local function dependencies()
    for _, name in ipairs({ "TITAN_VITE_ROOT", "TITAN_PLAYWRIGHT_ROOT" }) do
        if not os.getenv(name) or os.getenv(name) == "" then
            local reason = "browser documentation check requires " .. name
            if os.getenv("TITAN_REQUIRE_BROWSER_DEPLOYMENT") == "1" then error(reason) end
            return nil, reason
        end
    end
    return toolchain.require({ node = true, sdk = true })
end

describe("browser chapter examples", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    -- The manual's development server, through its loopback test module. Both
    -- files are copied into one source tree: no standard-library test tree
    -- resolves modules from the manual.
    it("serves files and refuses traversal with http-dev-server.titan", function()
        if platform.windows then pending("the browser host and http-dev-server's test fixture are POSIX") return end
        fixture = files.new()
        files.copy(repository .. "/doc/language/http-dev-server.titan", fixture.source .. "/http-dev-server.titan")
        files.copy(repository .. "/spec/fixtures/browser_docs/http_dev_server_test.titan",
            fixture.source .. "/http_dev_server_test.titan")
        local tests = fixture.output .. "/http-dev-server-tests"
        fixture:compiled({ "-q", "--test", "--exe", tests, "http_dev_server_test" })
        local result = fixture:run({ tests })
        assert.is_true(result.ok, result.output)
        local ran = tonumber(result.output:match("%[==========%] (%d+) tests ran%."))
        local passed = tonumber(result.output:match("%[  PASSED  %] (%d+) tests%."))
        assert.truthy(ran and ran >= 44, result.output)
        assert.equal(ran, passed, result.output)
    end)

    -- The chapter's opening, run block by block by doc_check, then its pages
    -- in Chromium through the documented server: plain HTTP, locateFile and
    -- Vite. No SDK loader is served. The complete application has its own
    -- section, which the hosted deployment test builds and serves.
    it("builds, serves and bundles the first web page exactly as documented", function()
        local info, why = dependencies()
        if not info then pending(why) return end
        fixture = files.new() -- Includes the ordinary compiler child-coverage collector.
        local workspace = fixture.root .. "/docs"
        files.mkdir(workspace)
        local opening = assert(doc_check.section(read(repository .. "/doc/language/browser-target.md"),
            "A first web page"))
        local plan = assert(doc_check.plan({ { name = "doc/language/browser-target.md", text = opening } },
            { workspace = workspace, source = repository, vite_root = os.getenv("TITAN_VITE_ROOT") }))
        local node_directory = info.node.path:match("^(.*)/[^/]+$")
        -- The reader's shell: the installation on PATH and no Titan overrides.
        assert(doc_check.run(plan, {
            PATH = info.prefix .. "/bin:" .. node_directory .. ":" .. (os.getenv("PATH") or ""),
            TITAN_ROOT = false, TITAN_TARGET = false, TITAN_PATH_0_6 = false, TITAN_PATH = false,
            TITAN_EXTRA_CPPFLAGS = false, TITAN_EXTRA_CFLAGS = false, TITAN_EXTRA_LDFLAGS = false,
        }))
        toolchain.check_imports(workspace .. "/out/hello.mjs", { "entry" })
        local expected = workspace .. "/expected-page.txt"
        files.write(expected, assert(plan.expectations.page))
        local result = fixture:run({ info.node.path, repository .. "/spec/fixtures/browser_docs/docs.mjs",
            workspace, expected }, {
                TITAN_VITE_ROOT = os.getenv("TITAN_VITE_ROOT"),
                TITAN_PLAYWRIGHT_ROOT = os.getenv("TITAN_PLAYWRIGHT_ROOT"),
            })
        io.stdout:write("\nBROWSER-DOCS ", result.output, "\n")
        io.stdout:flush()
        assert.is_true(result.ok, result.output)
        assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
        assert.truthy(result.output:find('"nodeDefault":true', 1, true), result.output)
        assert.truthy(result.output:find('"missingTrace":"failed"', 1, true), result.output)
        assert.truthy(result.output:find('"pages":3', 1, true), result.output)
        assert.truthy(result.output:find('"vite":"8.3.6"', 1, true), result.output)
    end)
end)

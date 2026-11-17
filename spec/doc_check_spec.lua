local assert = require "luassert"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

local doc_check = dofile("scripts/doc_check.lua")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("a")); file:close()
    return text
end

local function markdown(...)
    return table.concat({ ... }, "\n") .. "\n"
end

local function plan(text, options)
    options = options or {}
    options.workspace = options.workspace or "/work"
    return doc_check.plan({ { name = "doc.md", text = text } }, options)
end

local function rejects(text, needle, options)
    local result, err = plan(text, options)
    assert.is_nil(result)
    assert.truthy(err:find(needle, 1, true), err)
end

describe("doc-check markers", function()
    it("reads files, commands, expected text and the checkout block in document order", function()
        local blocks = assert(doc_check.parse(markdown(
            "Intro.", "",
            "<!-- doc-check: file=site/index.html -->", "```html", "<p>hi</p>", "```", "",
            "<!-- doc-check: run -->", "", "```sh", "make page", "```",
            "* A list item:", "",
            "  <!-- doc-check: expect=page -->", "  ```text", "  line one", "", "  line two", "  ```",
            "<!-- doc-check: setup=checkout -->", "````sh", "git clone x", "```", "````"), "doc.md"))
        assert.equal(4, #blocks)
        assert.same({ kind = "file", path = "site/index.html", document = "doc.md", line = 4,
            info = "html", body = "<p>hi</p>\n" }, blocks[1])
        assert.same({ kind = "run", document = "doc.md", line = 10, info = "sh", body = "make page\n" }, blocks[2])
        assert.same({ kind = "expect", label = "page", document = "doc.md", line = 16, info = "text",
            body = "line one\n\nline two\n" }, blocks[3])
        assert.same({ kind = "setup", document = "doc.md", line = 22, info = "sh",
            body = "git clone x\n```\n" }, blocks[4])
    end)

    it("never runs an unmarked block, nor a marker written inside one", function()
        local result = assert(plan(markdown(
            "```sh", "rm -rf unmarked", "```",
            "````markdown", "<!-- doc-check: run -->", "```sh", "echo inner", "```", "````",
            "<!-- doc-check: run -->", "```sh", "echo marked", "```")))
        assert.is_nil(result.script:find("unmarked", 1, true))
        assert.is_nil(result.script:find("inner", 1, true))
        assert.truthy(result.script:find("\necho marked\n", 1, true), result.script)
    end)

    it("rejects unknown, malformed and dangling markers and unsafe paths", function()
        rejects(markdown("<!-- doc-check: serve -->", "```sh", "x", "```"), "doc.md:1: unknown doc-check marker 'serve'")
        rejects(markdown("<!-- doc-check: expect= -->", "```text", "x", "```"), "unknown doc-check marker 'expect='")
        rejects(markdown("<!-- doc-check run -->", "```sh", "x", "```"), "doc.md:1: malformed doc-check marker")
        rejects(markdown("<!-- doc-check: run -->", "Text.", "```sh", "x", "```"), "is not followed by a fenced block")
        rejects(markdown("<!-- doc-check: run -->", "```sh", "x"), "unterminated fenced block")
        rejects(markdown("<!-- doc-check: run -->", "```bash", "x", "```"), "doc-check run needs an sh block, not 'bash'")
        rejects(markdown("<!-- doc-check: setup=checkout -->", "```", "x", "```"), "needs an sh block, not ''")
        rejects(markdown("<!-- doc-check: setup=release -->", "```sh", "x", "```"), "unknown doc-check marker")
        for _, path in ipairs({ "/etc/passwd", "../out.txt", "site/../../x", "./x", "a b", "site/" }) do
            rejects(markdown("<!-- doc-check: file=" .. path .. " -->", "```", "x", "```"), "file path " .. path)
        end
        rejects(markdown("  <!-- doc-check: run -->", "  ```sh", "  x", " y", "  ```"),
            "doc.md:4: line is indented less than its fence")
        rejects(markdown("<!-- doc-check: expect=page -->", "```text", "a", "```",
            "<!-- doc-check: expect=page -->", "```text", "b", "```"), "doc.md:6: expect=page appears twice")
    end)
end)

describe("doc-check substitutions", function()
    local clone = "git clone --recurse-submodules https://github.com/mascarenhas/titan"

    it("replaces exactly the documented spellings and logs each one", function()
        local result = assert(plan(markdown(
            "<!-- doc-check: setup=checkout -->", "```sh", clone, "cd titan",
            'export PREFIX="$HOME/.local/titan/my-project"', "```",
            "<!-- doc-check: run -->", "```sh", "cp /path/to/titan/doc/x.titan .",
            "npm install --save-dev vite", "```"), {
                checkout = "/ci/checkout", prefix = "/ci/prefix", source = "/ci/source", vite_root = "/ci/vite" }))
        assert.truthy(result.script:find(markdown(
            "git -c protocol.file.allow=always clone --recurse-submodules '/ci/checkout' titan", "cd titan",
            'export PREFIX="/ci/prefix"'), 1, true), result.script)
        assert.truthy(result.script:find(markdown("cp /ci/source/doc/x.titan .",
            "ln -s '/ci/vite/node_modules' node_modules"), 1, true), result.script)
        assert.same({
            "doc.md:2: " .. clone ..
                " -> git -c protocol.file.allow=always clone --recurse-submodules '/ci/checkout' titan",
            "doc.md:2: $HOME/.local/titan/my-project -> /ci/prefix",
            "doc.md:8: /path/to/titan -> /ci/source",
            "doc.md:8: npm install --save-dev vite -> ln -s '/ci/vite/node_modules' node_modules",
        }, result.substitutions)
    end)

    it("leaves file contents and expected text alone", function()
        local result = assert(plan(markdown(
            "<!-- doc-check: file=notes.txt -->", "```", "/path/to/titan", "```",
            "<!-- doc-check: expect=page -->", "```text", "/path/to/titan", "```")))
        assert.truthy(result.script:find("\n/path/to/titan\nDOC_CHECK_EOF_1\n", 1, true), result.script)
        assert.equal("/path/to/titan\n", result.expectations.page)
        assert.same({}, result.substitutions)
    end)

    it("requires the option of every substitution a command needs, and a use for every option", function()
        rejects(markdown("<!-- doc-check: run -->", "```sh", "cp /path/to/titan/x .", "```"),
            "doc.md:2: '/path/to/titan' needs --source")
        rejects(markdown("<!-- doc-check: run -->", "```sh", "npm install --save-dev vite", "```"),
            "needs --vite-root")
        rejects(markdown("<!-- doc-check: run -->", "```sh", "true", "```"),
            "--prefix given, but no block runs '$HOME/.local/titan/my-project'", { prefix = "/ci/prefix" })
        rejects(markdown("<!-- doc-check: setup=checkout -->", "```sh", "git clone elsewhere", "```"),
            "doc.md:2: the checkout block does not run '" .. clone .. "'", { checkout = "/ci/checkout" })
        -- Only the checkout block may clone the commit under test.
        rejects(markdown("<!-- doc-check: run -->", "```sh", clone, "```"),
            "--checkout given, but no block runs", { checkout = "/ci/checkout" })
    end)
end)

describe("doc-check execution", function()
    local workspace

    before_each(function()
        if platform.windows then return end
        workspace = temporary.name(); assert(os.remove(workspace)); assert(lfs.mkdir(workspace))
    end)

    after_each(function()
        if workspace then os.execute("rm -rf '" .. workspace .. "'"); workspace = nil end
    end)

    it("runs every document's blocks in one shell that starts each document in the workspace", function()
        if platform.windows then pending("doc-check runs POSIX sh") return end
        local first = markdown(
            "<!-- doc-check: file=app/hello.txt -->", "```", "it's $HOME", "", "```",
            "<!-- doc-check: run -->", "```sh", "cd app", "export GREETING=hi", "```",
            "<!-- doc-check: run -->", "```sh", 'printf "%s\\n" "$GREETING" > greeting.txt', "```")
        local second = markdown(
            "<!-- doc-check: run -->", "```sh", "cat app/hello.txt app/greeting.txt > both.txt", "```")
        local result = assert(doc_check.plan({ { name = "one.md", text = first }, { name = "two.md", text = second } },
            { workspace = workspace }))
        assert.is_true(doc_check.run(result))
        assert.equal("it's $HOME\n\n", read(workspace .. "/app/hello.txt"))
        assert.equal("it's $HOME\n\nhi\n", read(workspace .. "/both.txt"))
    end)

    it("stops at the first failing command", function()
        if platform.windows then pending("doc-check runs POSIX sh") return end
        local result = assert(plan(markdown(
            "<!-- doc-check: run -->", "```sh", "false", "touch after", "```"), { workspace = workspace }))
        local ok, err = doc_check.run(result)
        assert.is_nil(ok)
        assert.truthy(err:find("doc-check script failed", 1, true), err)
        assert.is_nil(lfs.attributes(workspace .. "/after"))
    end)
end)

describe("doc-check chapters", function()
    it("plans the installation and browser chapters with the job's substitutions", function()
        local result = assert(doc_check.plan({
            { name = "doc/language/installation.md", text = read("doc/language/installation.md") },
            { name = "doc/language/browser-target.md", text = read("doc/language/browser-target.md") },
        }, { workspace = "/work", checkout = "/ci/checkout", prefix = "/ci/prefix", source = "/ci/source",
            vite_root = "/ci/vite" }))
        assert.equal(4, #result.substitutions)
        assert.truthy(result.expectations.page:find("^Hello, browser, from Titan!\n"), result.expectations.page)
        for _, needle in ipairs({ "make browser-sdk PREFIX=", "titanc --target browser -o out hello",
                "cat > '/work/site/index.html'", "cat > '/work/site-assets/index.html'",
                "titanc -o out-native --exe http-dev-server http-dev-server", "npx vite build" }) do
            assert.truthy(result.script:find(needle, 1, true), needle)
        end
    end)
end)

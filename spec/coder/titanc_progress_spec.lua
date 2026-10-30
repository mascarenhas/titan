local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

local REPO = assert(lfs.currentdir())
local PREFIX = require("spec.support.installed_prefix").active()
local EXE_SUFFIX = platform.windows and ".exe" or ""
local LUA = PREFIX .. "/bin/lua" .. EXE_SUFFIX
-- The installed compiler program, or the checkout script under the checkout
-- Busted profile (after a reinstall the installed program is the same code).
local INSTALLED_TITANC = PREFIX .. "/bin/titanc" .. EXE_SUFFIX
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function quote(text)
    return assert(cdriver.shell_quote(text))
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert(lfs.mkdir(path), "could not create " .. path)
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function workspace()
    local reservation = assert(compiler_io.new_sync():tmpname())
    assert(os.remove(reservation))
    assert(lfs.mkdir(reservation))
    return reservation
end

-- One titanc invocation with separately captured streams. The child's stderr
-- is a file, so a normal run selects the plain renderer deterministically.
local function run(arguments, cwd)
    -- A parent jobserver would cap the probe and C job bounds; these cases
    -- choose their own jobs per invocation.
    local words = { "env", "-u", "LUA_PATH", "-u", "LUA_CPATH", "-u",
        "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5", "-u", "NO_COLOR",
        "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
        "TITAN_PATH=", "TITAN_ROOT=" .. PREFIX }
    for _, word in ipairs(arguments) do
        words[#words + 1] = quote(word)
    end
    local stdout_path = cwd .. "/.titanc-progress.stdout"
    local stderr_path = cwd .. "/.titanc-progress.stderr"
    local command = table.concat(words, " ") .. " > " ..
        quote(stdout_path) .. " 2> " .. quote(stderr_path)
    local previous = assert(lfs.currentdir())
    assert(lfs.chdir(cwd))
    local called, result = pcall(function()
        return compiler_io.new_sync():run({ "sh", "-c", command }, {
            inherit_environment = true,
        })
    end)
    assert(lfs.chdir(previous))
    assert.truthy(called, result)
    local stdout = read_file(stdout_path) or ""
    local stderr = read_file(stderr_path) or ""
    os.remove(stdout_path)
    os.remove(stderr_path)
    return result.ok == true, stdout, stderr, result.why, result.status
end

local function compiler(arguments)
    local argv = {}
    if USE_CHECKOUT_COMPILER then
        argv[#argv + 1] = LUA
        argv[#argv + 1] = "-E"
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = string.format("package.path=%q..package.path",
            REPO .. "/?.lua;" .. REPO .. "/?/init.lua;")
        argv[#argv + 1] = REPO .. "/titanc"
    else
        argv[#argv + 1] = INSTALLED_TITANC
    end
    for _, word in ipairs(arguments) do argv[#argv + 1] = word end
    return argv
end

local function lines(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do result[#result + 1] = line end
    return result
end

local function first_line_matching(text, pattern)
    for _, line in ipairs(lines(text)) do
        if line:find(pattern) then return line, text:find(line, 1, true) end
    end
    return nil
end

local function expect_line(text, pattern, description)
    local line = first_line_matching(text, pattern)
    assert.truthy(line, "missing " .. description .. ": " .. pattern ..
        "\n--- stderr ---\n" .. text)
    return line
end

local function position(text, line)
    return assert(text:find(line, 1, true))
end

describe("titanc progress reporting", function()
    if platform.windows then
        it("is exercised by the POSIX process harness", function()
            pending("titanc progress console output runs in the Windows lanes")
        end)
        return
    end

    local root
    local source = root
    local output

    setup(function()
        root = workspace()
        source = root .. "/src"
        output = root .. "/out"
        make_directory(source .. "/app")
        write_file(source .. "/app/one.titan", table.concat({
            "function greet(): string",
            '  return "one"',
            "end",
            "",
        }, "\n"))
        write_file(source .. "/app/two.titan", table.concat({
            'local one = import "app.one"',
            "",
            "function twice(): string",
            "  return one.greet() .. one.greet()",
            "end",
            "",
        }, "\n"))
        write_file(source .. "/bad.titan", table.concat({
            "function broken(): integer",
            '  return "not an integer"',
            "end",
            "",
        }, "\n"))
        write_file(root .. "/helper.c",
            "int titanc_progress_helper(void) { return 7; }\n")
    end)

    teardown(function()
        if root then remove_tree(root) end
    end)

    it("reports every module phase and the link step on stderr", function()
        local ok, stdout, stderr = run(compiler({
            "--tree", source, "--output", output, "app.one", "app.two",
        }), root)
        assert.truthy(ok, stderr)
        assert.equal("", stdout)
        for _, name in ipairs({ "app.one", "app.two" }) do
            local escaped = name:gsub("%.", "%%.")
            local parsed = expect_line(stderr, "^" .. escaped .. " %.+ parsing$", "parsing")
            local checked = expect_line(stderr, "^" .. escaped .. " %.+ checking$", "checking")
            local generated = expect_line(stderr,
                "^" .. escaped .. " %.+ generating C$", "code generation")
            local compiled = expect_line(stderr,
                "^" .. escaped .. " %.+ compiling C$", "C compilation")
            local done = expect_line(stderr, "^" .. escaped .. " %.+ done %d+%.%ds$", "completion")
            assert.truthy(position(stderr, parsed) < position(stderr, checked))
            assert.truthy(position(stderr, checked) < position(stderr, generated))
            assert.truthy(position(stderr, generated) < position(stderr, compiled))
            assert.truthy(position(stderr, compiled) < position(stderr, done))
        end
        local linking = expect_line(stderr, "^app%.so %.+ linking$", "link step")
        expect_line(stderr, "^app%.so %.+ done %d+%.%ds$", "link completion")
        expect_line(stderr, "^Finished in .*: 2 compiled, linked app%.so$", "summary")
        -- The default mode names modules and phases, never command lines.
        for _, line in ipairs(lines(stderr)) do
            assert.is_nil(line:find("gcc", 1, true), line)
            assert.is_nil(line:find(" -c ", 1, true), line)
        end
        -- Everything the link step reports follows the module lines.
        local link_position = position(stderr, linking)
        for _, line in ipairs(lines(stderr)) do
            if line:find("^app%.one %.+ done") or line:find("^app%.two %.+ done") then
                assert.truthy(position(stderr, line) < link_position, line)
            end
        end
    end)

    it("reports up-to-date modules and the link certificate hit", function()
        local ok, stdout, stderr = run(compiler({
            "--tree", source, "--output", output, "--incremental",
            "app.one", "app.two",
        }), root)
        assert.truthy(ok, stderr)
        assert.equal("", stdout)
        expect_line(stderr, "^2 modules up to date$", "up-to-date summary")
        expect_line(stderr, "^app%.so %.+ up to date$", "link certificate hit")
        expect_line(stderr,
            "^Finished in .*: 2 up to date, app%.so up to date$", "summary")
        -- The hit output is never reported as linked.
        assert.is_nil(stderr:find("linked", 1, true), stderr)
        for _, line in ipairs(lines(stderr)) do
            assert.is_nil(line:find("parsing", 1, true), line)
            assert.is_nil(line:find("compiling", 1, true), line)
        end
    end)

    it("prints nothing at all in quiet mode", function()
        local quiet_output = root .. "/quiet-out"
        local ok, stdout, stderr = run(compiler({
            "-q", "--tree", source, "--output", quiet_output,
            "app.one", "app.two",
        }), root)
        assert.truthy(ok, stderr)
        assert.equal("", stdout)
        assert.equal("", stderr)
    end)

    it("refuses -q together with -v, naming both switches", function()
        local ok, stdout, stderr = run(compiler({
            "-q", "-v", "--tree", source, "--output", output, "app.one",
        }), root)
        assert.is_false(ok)
        assert.equal("", stdout)
        assert.equal("-q/--quiet and -v/--verbose cannot be combined\n", stderr)
    end)

    it("reports a failed module before its diagnostics", function()
        local ok, stdout, stderr = run(compiler({
            "--tree", source, "--output", root .. "/bad-out", "bad",
        }), root)
        assert.is_false(ok)
        assert.equal("", stdout)
        local failed = expect_line(stderr, "^bad %.+ failed$", "module failure")
        local summary = expect_line(stderr, "^Failed after %d+%.%ds$", "failure summary")
        local diagnostic = expect_line(stderr, "type error", "diagnostic")
        assert.truthy(position(stderr, failed) < position(stderr, summary))
        assert.truthy(position(stderr, summary) < position(stderr, diagnostic))
    end)

    it("keeps -q failure output to the diagnostics", function()
        local ok, stdout, stderr = run(compiler({
            "-q", "--tree", source, "--output", root .. "/bad-quiet", "bad",
        }), root)
        assert.is_false(ok)
        assert.equal("", stdout)
        local captured = lines(stderr)
        assert.equal(1, #captured)
        assert.truthy(captured[1]:find("type error", 1, true), captured[1])
        assert.truthy(captured[1]:find("bad.titan:2:10:", 1, true), captured[1])
    end)

    it("reports probe batches during checking as no phase at all", function()
        -- Four C operators defer the checker's acceptance probes, so a
        -- native batch arrives while the module is still checking. Only the
        -- worker names phases; a batch never adds or clears one.
        local header = REPO .. "/spec/fixtures/speculative_probes/speculative.h"
        local tree = root .. "/probe-src"
        make_directory(tree)
        write_file(tree .. "/probe_module.titan", table.concat({
            'foreign import "' .. header .. '"',
            '',
            "local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int",
            "  return a + b",
            "end",
            "",
            "local function widen(a: foreign spec_wide_t, b: foreign spec_ok_t): foreign long",
            "  return a * b",
            "end",
            "",
            "local function again(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int",
            "  return a - b",
            "end",
            "",
            "local function view(p: foreign *spec_item): foreign *spec_other",
            "  return p",
            "end",
            "",
            "function check(): integer",
            "  return 0",
            "end",
            "",
        }, "\n"))
        local ok, stdout, stderr = run(compiler({
            "-j", "4", "--tree", tree, "--output", root .. "/probe-out",
            "probe_module",
        }), root)
        assert.truthy(ok, stderr)
        assert.equal("", stdout)
        local phases = {}
        for _, line in ipairs(lines(stderr)) do
            local state = line:match("^probe_module %.+ (.*)$")
            if state then
                phases[#phases + 1] = (state:gsub("^done %d+%.%ds$", "done"))
            end
        end
        assert.same({
            "parsing", "checking", "generating C", "compiling C", "done",
        }, phases)
    end)

    it("reports no step for an authored C source that fails before compiling", function()
        -- The preprocessing step fails, before the compile begins, so there is
        -- no step to finish: no begin line, no failed line, no summary.
        local broken = root .. "/missing_header.c"
        write_file(broken, '#include "no_such_header_322.h"\n' ..
            "int missing(void) { return 0; }\n")
        local ok, stdout, stderr = run(compiler({
            "-c", "--output", root .. "/missing-native", "--c-source", broken,
        }), root)
        assert.is_false(ok)
        assert.equal("", stdout)
        -- The compiler's own diagnostic is unchanged.
        assert.truthy(stderr:find("no_such_header_322.h", 1, true), stderr)
        assert.is_nil(first_line_matching(stderr,
            "^%S*missing_header%.c %.+ compiling C source$"), stderr)
        assert.is_nil(first_line_matching(stderr,
            "^%S*missing_header%.c %.+ failed$"), stderr)
        assert.is_nil(stderr:find("Failed after", 1, true), stderr)
    end)

    it("reports a failed authored C source before its diagnostics", function()
        local broken = root .. "/broken.c"
        write_file(broken, "int broken(void) { return }\n")
        local ok, stdout, stderr = run(compiler({
            "-c", "--output", root .. "/broken-native", "--c-source", broken,
        }), root)
        assert.is_false(ok)
        assert.equal("", stdout)
        local begun = expect_line(stderr, "broken%.c %.+ compiling C source$",
            "C source step")
        local failed = expect_line(stderr, "broken%.c %.+ failed$",
            "C source failure")
        local summary = expect_line(stderr, "^Failed after %d+%.%ds$",
            "failure summary")
        assert.truthy(position(stderr, begun) < position(stderr, failed))
        assert.truthy(position(stderr, failed) < position(stderr, summary))
        -- The compiler's own diagnostics follow unchanged.
        local diagnostic = expect_line(stderr, "error", "compiler diagnostic")
        assert.truthy(position(stderr, summary) < position(stderr, diagnostic))
    end)

    it("keeps --print-c-objects stdout to certified paths", function()
        local native_output = root .. "/native"
        local arguments = {
            "-c", "--incremental", "--print-c-objects", "--output", native_output,
            "--c-source", root .. "/helper.c",
        }
        local ok, stdout, stderr = run(compiler(arguments), root)
        assert.truthy(ok, stderr)
        local reported = lines(stdout)
        assert.equal(1, #reported)
        assert.truthy(reported[1]:match("^/"), reported[1])
        assert.truthy(reported[1]:match("%.o$"), reported[1])
        -- The authored C source is a visible step, and it stays on stderr.
        expect_line(stderr, "helper%.c %.+ compiling C source$", "C source step")
        expect_line(stderr, "helper%.c %.+ done %d+%.%ds$", "C source completion")

        -- A certified hit is counted in the summary instead of stepping again.
        local again, quiet_stdout, quiet_stderr = run(compiler(arguments), root)
        assert.truthy(again, quiet_stderr)
        assert.equal(stdout, quiet_stdout)
        assert.is_nil(quiet_stderr:find("compiling C source", 1, true), quiet_stderr)
        expect_line(quiet_stderr,
            "^Finished in .*: 1 C source up to date$", "hit summary")
    end)
end)

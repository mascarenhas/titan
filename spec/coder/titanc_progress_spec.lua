local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local luacov_children = require "spec.support.luacov_children"
local terminal = require "spec.support.terminal_screen"

local REPO = assert(lfs.currentdir())
local PREFIX = require("spec.support.installed_prefix").active()
local EXE_SUFFIX = platform.windows and ".exe" or ""
local LUA = PREFIX .. "/bin/lua" .. EXE_SUFFIX
-- Every CLI child runs a private copy of this checkout's compiler so the
-- behaviour it exercises can be enrolled with LuaCov (a subprocess is never
-- measured by the parent runner). `frontend`/`children` are set in `setup`.
local frontend, children, frontend_wrapper

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

local function copy_tree(source, destination)
    if lfs.attributes(source, "mode") == "directory" then
        assert(lfs.mkdir(destination), "could not create " .. destination)
        for entry in lfs.dir(source) do
            if entry ~= "." and entry ~= ".." then
                copy_tree(source .. "/" .. entry, destination .. "/" .. entry)
            end
        end
        return
    end
    write_file(destination, assert(read_file(source)))
end

local function workspace()
    local reservation = assert(compiler_io.new_sync():tmpname())
    assert(os.remove(reservation))
    assert(lfs.mkdir(reservation))
    return reservation
end

-- One titanc invocation with separately captured streams. The child's stderr
-- is a file, so a normal run selects the plain renderer deterministically.
local function shell(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = assert(pipe:read("a"))
    local ok = pipe:close()
    return ok == true, output
end

-- The live case needs util-linux `script` (``-q -f -e -c <command> <file>``).
-- BSD/macOS `script` takes `script -q <file> <command...>` and rejects these
-- flags, so probe the exact form and skip elsewhere instead of failing the
-- platform gate. The probe writes a short-lived explicit typescript file, so
-- it never leaves `script`'s default file behind.
local function script_supports_command_form()
    local script_file = assert(compiler_io.new_sync():tmpname())
    os.remove(script_file)
    local ok, output = shell("script -qfec 'printf titan-script-probe' " ..
        quote(script_file))
    os.remove(script_file)
    return ok and output:find("titan-script-probe", 1, true) ~= nil
end

-- One titanc invocation with separately captured streams. The child's stderr
-- is a file, so a normal run selects the plain renderer deterministically.
-- `environment` adds NAME=value assignments to the child.
local function run(arguments, cwd, environment)
    -- A parent jobserver would cap the probe and C job bounds; these cases
    -- choose their own jobs per invocation.
    local words = { "env", "-u", "LUA_PATH", "-u", "LUA_CPATH", "-u",
        "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5", "-u", "NO_COLOR",
        "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
        "TITAN_PATH=", "TITAN_ROOT=" .. PREFIX }
    for _, assignment in ipairs(environment or {}) do
        words[#words + 1] = assignment
    end
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
    if children then children:collect() end
    local stdout = read_file(stdout_path) or ""
    local stderr = read_file(stderr_path) or ""
    os.remove(stdout_path)
    os.remove(stderr_path)
    return result.ok == true, stdout, stderr, result.why, result.status
end

local function compiler(arguments)
    local argv = { LUA, "-E", frontend_wrapper }
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
        write_file(source .. "/app_main.titan", table.concat({
            "function main(args: {string}): integer",
            "  return 0",
            "end",
            "",
        }, "\n"))
        -- The CLI children run this checkout's compiler from a private copy so
        -- their behaviour (reporter creation, -q/-v, worker records, steps)
        -- counts under LuaCov; the helper is a no-op otherwise.
        frontend = root .. "/tooling"
        make_directory(frontend)
        for _, name in ipairs({ "titan-compiler", "c-parser", "titanc" }) do
            copy_tree(REPO .. "/" .. name, frontend .. "/" .. name)
        end
        children = luacov_children.new(REPO, frontend, root .. "/child-luacov")
        frontend_wrapper = root .. "/frontend.lua"
        write_file(frontend_wrapper, table.concat({
            "package.path = " .. string.format("%q", frontend .. "/?.lua;") ..
                " .. package.path",
            children:init_code(),
            "dofile(" .. string.format("%q", frontend .. "/titanc") .. ")",
            "",
        }, "\n"))
    end)

    teardown(function()
        if root then remove_tree(root) end
    end)

    local function rejecting_archive_tools(label, failure)
        local directory = root .. "/archive-tools-" .. label
        make_directory(directory)
        local log = directory .. "/calls"
        local ar = directory .. "/ar.sh"
        local ranlib = directory .. "/ranlib.sh"
        local ar_script = {
            "#!/bin/sh",
            'printf "ar %s\\n" "$1" >> ' .. quote(log),
            'case "$1" in',
            '    *D*) printf "fake ar: illegal option -- D\\nusage: fake ar\\n" >&2; exit 64 ;;',
            "esac",
        }
        if failure == "AR" then
            ar_script[#ar_script + 1] =
                'if [ "$1" = "qc" ]; then printf "usage: fake ar fallback\\n" >&2; exit 65; fi'
        elseif failure == "write" then
            ar_script[#ar_script + 1] =
                'case "$2" in */output.a) printf "actual archive write denied\\n" >&2; exit 68 ;; esac'
        end
        ar_script[#ar_script + 1] = 'exec ar "$@"'
        ar_script[#ar_script + 1] = ""
        write_file(ar, table.concat(ar_script, "\n"))
        local ranlib_script = {
            "#!/bin/sh",
            'if [ "$1" = "-D" ]; then',
            '    printf "ranlib -D\\n" >> ' .. quote(log),
            '    printf "fake ranlib: illegal option -- D\\nusage: fake ranlib\\n" >&2',
            "    exit 66",
            "fi",
            'printf "ranlib ordinary\\n" >> ' .. quote(log),
        }
        ranlib_script[#ranlib_script + 1] = failure == "RANLIB" and
            'printf "usage: fake ranlib fallback\\n" >&2; exit 67' or 'exec ranlib "$@"'
        ranlib_script[#ranlib_script + 1] = ""
        write_file(ranlib, table.concat(ranlib_script, "\n"))
        assert.truthy(shell("chmod +x " .. quote(ar) .. " " .. quote(ranlib)))
        return { "AR=" .. quote(ar), "RANLIB=" .. quote(ranlib) }, log
    end

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
        -- This case owns its output tree: the measured rebuild is seeded by a
        -- cold build here, so it never depends on another case having run.
        local hit_output = root .. "/hit-out"
        local seeded, _, seed_stderr = run(compiler({
            "--tree", source, "--output", hit_output, "app.one", "app.two",
        }), root)
        assert.truthy(seeded, seed_stderr)
        expect_line(seed_stderr,
            "^Finished in .*: 2 compiled, linked app%.so$", "seed summary")

        local ok, stdout, stderr = run(compiler({
            "--tree", source, "--output", hit_output, "--incremental",
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

    it("keeps rejected archive capability diagnostics out of quiet output", function()
        local environment, log = rejecting_archive_tools("fallback")
        local quiet_output = root .. "/quiet-archive-fallback"
        local ok, stdout, stderr = run(compiler({
            "-q", "--tree", source, "--output", quiet_output, "app.one", "app.two",
        }), root, environment)
        assert.truthy(ok, stderr)
        assert.equal("", stdout)
        assert.equal("", stderr)
        local calls = assert(read_file(log))
        assert.truthy(calls:find("ar qDc\n", 1, true), calls)
        assert.truthy(calls:find("ar qc\n", 1, true), calls)
        assert.truthy(calls:find("ranlib -D\n", 1, true), calls)
        assert.truthy(calls:find("ranlib ordinary\n", 1, true), calls)
        assert.equal("file", lfs.attributes(quiet_output .. "/app.a", "mode"))
    end)

    for _, failure in ipairs({ { "AR", "neither qDc nor qc", 65 },
            { "RANLIB", "neither -D nor ordinary mode", 67 } }) do
        it("preserves a rejected " .. failure[1] .. " capability verdict without leaking usage", function()
            local environment = rejecting_archive_tools("failed-" .. failure[1], failure[1])
            local quiet_output = root .. "/quiet-archive-failed-" .. failure[1]
            local ok, stdout, stderr = run(compiler({
                "-q", "--tree", source, "--output", quiet_output, "app.one", "app.two",
            }), root, environment)
            assert.is_false(ok)
            assert.equal("", stdout)
            assert.truthy(stderr:find("configured " .. failure[1] .. " supports " ..
                failure[2] .. " (exit, exit " .. failure[3] .. ")", 1, true), stderr)
            assert.is_nil(stderr:find("usage: fake", 1, true), stderr)
            assert.is_nil(lfs.attributes(quiet_output .. "/app.a"))
        end)
    end

    it("retains real archive-write diagnostics in quiet mode", function()
        local environment = rejecting_archive_tools("write-failure", "write")
        local ok, stdout, stderr = run(compiler({
            "-q", "--tree", source, "--output", root .. "/quiet-archive-write-failed",
            "app.one", "app.two",
        }), root, environment)
        assert.is_false(ok)
        assert.equal("", stdout)
        assert.truthy(stderr:find("actual archive write denied", 1, true), stderr)
        assert.is_nil(stderr:find("usage: fake", 1, true), stderr)
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

    it("keeps a provider-pair link diagnostic visible in the live region", function()
        if not script_supports_command_form() then
            pending("needs util-linux `script` (-qfec); the BSD/macOS form is unsupported")
            return
        end
        -- A wrapper compiler fails the shared provider link with a diagnostic
        -- that does not end in a newline, on both captured streams.
        local wrapper = root .. "/deny_link.sh"
        write_file(wrapper, table.concat({
            "#!/bin/sh",
            'for argument in "$@"; do',
            '    if [ "$argument" = "-shared" ]; then',
            "        printf 'link denied out'",
            "        printf 'link denied err' >&2",
            "        exit 1",
            "    fi",
            "done",
            'exec cc "$@"',
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(wrapper)))

        local live_output = root .. "/live-link-out"
        local words = {}
        for _, word in ipairs(compiler({
            "--tree", source, "--output", live_output, "app.one", "app.two",
        })) do
            words[#words + 1] = quote(word)
        end
        local launcher = root .. "/live_link.sh"
        write_file(launcher, table.concat({
            "#!/bin/sh",
            "exec env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
                " -u NO_COLOR -u MAKEFLAGS -u MFLAGS -u MAKELEVEL" ..
                " TERM=xterm-256color LC_ALL=C LANG=C" ..
                " CC=" .. quote(wrapper) .. " TITAN_PATH= TITAN_ROOT=" ..
                quote(PREFIX) .. " " .. table.concat(words, " "),
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(launcher)))

        local typescript = root .. "/live-link.typescript"
        local ran = shell("script -qfec " .. quote(launcher) .. " " ..
            quote(typescript))
        assert.is_false(ran, "the failing link must exit nonzero")
        local transcript = read_file(typescript) or ""
        local screen = terminal.render(transcript)
        local rendered = table.concat(screen, "\n")
        -- Live mode really was selected: the region was drawn (erase-down) and
        -- its rows were parked/redrawn with cursor moves.
        assert.truthy(transcript:find("\27[J", 1, true),
            "no live redraw sequence in the transcript: " .. rendered)
        -- The captured stdout and stderr logs both survive the failure event,
        -- which erases and redraws the region.
        assert.is_true(terminal.shows(screen, "link denied out"), rendered)
        assert.is_true(terminal.shows(screen, "link denied err"), rendered)
        assert.is_true(terminal.shows(screen, "failed"), rendered)
        assert.is_nil(lfs.attributes(live_output .. "/app.so"), rendered)

        -- Quiet mode keeps the historical output for the same failure.
        local quiet_ok, _, quiet_stderr = run(compiler({
            "-q", "--tree", source, "--output", root .. "/live-link-quiet",
            "app.one", "app.two",
        }), root, { "CC=" .. wrapper })
        assert.is_false(quiet_ok)
        assert.truthy(quiet_stderr:find("link denied out", 1, true), quiet_stderr)
        assert.truthy(quiet_stderr:find("link denied err", 1, true), quiet_stderr)
        assert.is_nil(quiet_stderr:find("compiling C", 1, true), quiet_stderr)
    end)

    it("draws spinner frames while a slow provider link runs", function()
        if not script_supports_command_form() then
            pending("needs util-linux `script` (-qfec); the BSD/macOS form is unsupported")
            return
        end
        -- A native provider-pair link waits in the private completion poll,
        -- which runs no loop: without an idle frame the spinner of that row
        -- would freeze for the whole link. The wrapper holds each
        -- shared-library link for a second, then runs the real compiler, so
        -- the terminal transcript can count what was drawn meanwhile.
        local wrapper = root .. "/slow_link.sh"
        write_file(wrapper, table.concat({
            "#!/bin/sh",
            'for argument in "$@"; do',
            '    if [ "$argument" = "-shared" ]; then',
            "        sleep 1",
            "        break",
            "    fi",
            "done",
            'exec cc "$@"',
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(wrapper)))

        local words = {}
        for _, word in ipairs(compiler({
            "--tree", source, "--output", root .. "/live-slow-out",
            "app.one", "app.two",
        })) do
            words[#words + 1] = quote(word)
        end
        local launcher = root .. "/live_slow_link.sh"
        write_file(launcher, table.concat({
            "#!/bin/sh",
            "exec env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
                " -u NO_COLOR -u MAKEFLAGS -u MFLAGS -u MAKELEVEL" ..
                " TERM=xterm-256color LC_ALL=C LANG=C CC=" .. quote(wrapper) ..
                " TITAN_PATH= TITAN_ROOT=" .. quote(PREFIX) .. " " ..
                table.concat(words, " "),
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(launcher)))

        local typescript = root .. "/live-slow-link.typescript"
        local ran = shell("script -qfec " .. quote(launcher) .. " " ..
            quote(typescript))
        assert.is_true(ran, "the slow provider link must still succeed")
        if children then children:collect() end
        local transcript = read_file(typescript) or ""
        -- Escape sequences removed, every redraw of the link row counts once.
        local visible = transcript:gsub("\27%[[%d;]*%a", "")
        local frames, drawn = {}, 0
        for glyph in visible:gmatch("[\r\n]  ([-\\|/]) app%.so ") do
            drawn = drawn + 1
            frames[glyph] = true
        end
        local distinct = 0
        for _ in pairs(frames) do distinct = distinct + 1 end
        -- A frozen spinner draws the link row once per completed child (three
        -- times here: the start, and each wait's return); roughly ten frames a
        -- second draw many more and cycle through the four ASCII glyphs.
        assert.is_true(drawn >= 10,
            "the link row was drawn only " .. drawn .. " times")
        assert.is_true(distinct >= 3,
            "only " .. distinct .. " spinner frames were drawn")
        assert.truthy(visible:find("linked app.so", 1, true),
            table.concat(terminal.render(transcript), "\n"))
    end)

    it("reports a standalone program link in the live region", function()
        if not script_supports_command_form() then
            pending("needs util-linux `script` (-qfec); the BSD/macOS form is unsupported")
            return
        end
        local executable = root .. "/app-main"
        local words = {}
        for _, word in ipairs(compiler({
            "--tree", source, "--output", root .. "/program-out",
            "--exe", executable, "app_main",
        })) do
            words[#words + 1] = quote(word)
        end
        local launcher = root .. "/live_program.sh"
        write_file(launcher, table.concat({
            "#!/bin/sh",
            "exec env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
                " -u NO_COLOR -u MAKEFLAGS -u MFLAGS -u MAKELEVEL" ..
                " TERM=xterm-256color LC_ALL=C LANG=C TITAN_PATH= TITAN_ROOT=" ..
                quote(PREFIX) .. " TITAN_RUNTIME_PREBUILT=1 " ..
                table.concat(words, " "),
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(launcher)))

        local typescript = root .. "/live-program.typescript"
        local ran = shell("script -qfec " .. quote(launcher) .. " " ..
            quote(typescript))
        assert.is_true(ran, "the standalone program build must succeed")
        if children then children:collect() end
        local transcript = read_file(typescript) or ""
        local screen = terminal.render(transcript)
        local rendered = table.concat(screen, "\n")
        assert.truthy(transcript:find("\27[J", 1, true),
            "no live redraw sequence in the transcript: " .. rendered)
        -- One compiled module and one final link, named by the executable.
        assert.is_true(terminal.shows(screen, "ok app_main"), rendered)
        assert.is_true(terminal.shows(screen, "ok app-main"), rendered)
        assert.truthy(rendered:find("Finished in", 1, true), rendered)
        assert.truthy(rendered:find("linked app%-main"), rendered)
        assert.truthy(lfs.attributes(executable, "mode") == "file", rendered)
    end)

    it("keeps a failed standalone link diagnostic visible in the live region", function()
        if not script_supports_command_form() then
            pending("needs util-linux `script` (-qfec); the BSD/macOS form is unsupported")
            return
        end
        -- The wrapper fails only the final program link (it names the
        -- generated entrypoint), with a diagnostic that has no newline.
        local wrapper = root .. "/deny_program.sh"
        write_file(wrapper, table.concat({
            "#!/bin/sh",
            'for argument in "$@"; do',
            '    case "$argument" in',
            '        *__entrypoint.c)',
            "            printf 'program link denied' >&2",
            "            exit 1",
            "            ;;",
            "    esac",
            "done",
            'exec cc "$@"',
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(wrapper)))

        local words = {}
        for _, word in ipairs(compiler({
            "--tree", source, "--output", root .. "/program-fail-out",
            "--exe", root .. "/app-fail", "app_main",
        })) do
            words[#words + 1] = quote(word)
        end
        local launcher = root .. "/live_program_fail.sh"
        write_file(launcher, table.concat({
            "#!/bin/sh",
            "exec env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5" ..
                " -u NO_COLOR -u MAKEFLAGS -u MFLAGS -u MAKELEVEL" ..
                " TERM=xterm-256color LC_ALL=C LANG=C CC=" .. quote(wrapper) ..
                " TITAN_PATH= TITAN_ROOT=" .. quote(PREFIX) ..
                " TITAN_RUNTIME_PREBUILT=1 " .. table.concat(words, " "),
            "",
        }, "\n"))
        assert.truthy(shell("chmod +x " .. quote(launcher)))

        local typescript = root .. "/live-program-fail.typescript"
        local ran = shell("script -qfec " .. quote(launcher) .. " " ..
            quote(typescript))
        assert.is_false(ran, "the failing program link must exit nonzero")
        if children then children:collect() end
        local transcript = read_file(typescript) or ""
        local screen = terminal.render(transcript)
        local rendered = table.concat(screen, "\n")
        assert.truthy(transcript:find("\27[J", 1, true),
            "no live redraw sequence in the transcript: " .. rendered)
        -- The captured linker diagnostic survives the failed-step redraw.
        assert.is_true(terminal.shows(screen, "program link denied"), rendered)
        assert.is_true(terminal.shows(screen, "FAILED app-fail"), rendered)
        assert.truthy(rendered:find("Failed after", 1, true), rendered)
        assert.is_nil(lfs.attributes(root .. "/app-fail", "mode"), rendered)

        -- Quiet mode keeps the historical stderr for the same failure.
        local quiet_ok, _, quiet_stderr = run(compiler({
            "-q", "--tree", source, "--output", root .. "/program-fail-quiet",
            "--exe", root .. "/app-fail-quiet", "app_main",
        }), root, { "CC=" .. wrapper })
        assert.is_false(quiet_ok)
        assert.truthy(quiet_stderr:find("program link denied", 1, true),
            quiet_stderr)
        assert.is_nil(quiet_stderr:find("compiling C", 1, true), quiet_stderr)
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

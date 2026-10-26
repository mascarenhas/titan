-- Unix provider-pair pipeline: link overlap within the shared job budget,
-- both validation families, and publication rollback on either path.
-- Implementation notes: doc/implementation/static-compiled-modules.md#provider-link-pipeline
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

local REPO = assert(lfs.currentdir())
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local INSTALLED_TITANC = PREFIX .. "/bin/titanc"
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"
local CC = os.getenv("CC") or "cc"
local RANLIB = os.getenv("RANLIB") or "ranlib"

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function quote_words(words)
    local quoted = {}
    for index, word in ipairs(words) do quoted[index] = quote(word) end
    return table.concat(quoted, " ")
end

local function configured_words(command)
    return assert(cdriver.split_shell_words(command))
end

local function shell(directory, script)
    local result = compiler_io.new_sync():run({
        "sh", "-c", "cd " .. quote(directory) .. " && " .. script,
    })
    return result.started and result.ok, result.output or "", result.why,
        result.status
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents, executable)
    make_directory(assert(path:match("^(.+)/[^/]+$")))
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
    if executable then
        local ok, output = shell("/", "chmod u+x " .. quote(path))
        assert.truthy(ok, output)
    end
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("a")
    file:close()
    return contents
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

-- Every entry below `root`, including dot files, as sorted relative paths.
local function listing(root)
    local entries = {}
    local function visit(directory, prefix)
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then
                local relative = prefix .. name
                entries[#entries + 1] = relative
                if lfs.symlinkattributes(directory .. "/" .. name, "mode") ==
                   "directory" then
                    visit(directory .. "/" .. name, relative .. "/")
                end
            end
        end
    end
    visit(root, "")
    table.sort(entries)
    return entries
end

-- Permanent locks, preamble inputs and per-target link bookkeeping survive a
-- failed staged rebuild. A previous success record does not: the link gate
-- invalidates it before rebuilding. Keep every other entry visible so stage
-- leaks or newly published provider artifacts still fail the inventory check.
local function provider_artifacts(root, allow_success_record)
    local artifacts = {}
    for _, entry in ipairs(listing(root)) do
        local key, suffix = entry:match("^[.]titan%-links/([0-9a-f]+)(.*)$")
        local link_bookkeeping = key and #key == 64 and
            (suffix == "" or suffix == "/link.d" or suffix == "/record")
        if link_bookkeeping and suffix == "/record" then
            assert.truthy(allow_success_record, "failed link retained a success record: " .. entry)
        end
        if entry ~= ".titan-build.lock" and entry ~= ".titan" and
            entry ~= ".titan/preamble.c" and entry ~= ".titan-links" and
            not link_bookkeeping then
            artifacts[#artifacts + 1] = entry
        end
    end
    return artifacts
end

local function lines(path)
    local result = {}
    for line in (read_file(path) or ""):gmatch("[^\n]+") do
        result[#result + 1] = line
    end
    return result
end

local function position(list, wanted)
    for index, value in ipairs(list) do
        if value == wanted then return index end
    end
end

-- The two provider links are recognized by their private output names. The
-- staged DSO link can be held open (TITAN_TEST_LINK_HOLD): `image` until the
-- archive-backed link has started, `image-end` until it has finished,
-- `archive` until the staged archive has been indexed plus one second for
-- any (forbidden) image link to start, and `release` (either link) until the
-- test creates `<events>.release`. TITAN_TEST_FAIL_LINK names the failing
-- link kind, or `both`.
local LINK_WRAPPER = [[#!/bin/sh
events=%s
kind=
next_output=no
for argument in "$@"; do
    if [ "$next_output" = yes ]; then
        case "$argument" in
            */archive-validation.so) kind=image ;;
            *.stage.tmp.*/pkg.so) kind=dso ;;
        esac
        next_output=no
    elif [ "$argument" = "-o" ]; then
        next_output=yes
    fi
done
if [ -z "$kind" ]; then exec %s "$@"; fi
printf '%%s-start\n' "$kind" >> "$events"
%s "$@"
status=$?
tenths=0
settle=0
while [ "$tenths" -lt 600 ]; do
    case "$kind:${TITAN_TEST_LINK_HOLD:-}" in
        dso:image) grep -q '^image-start$' "$events" && break ;;
        dso:image-end) grep -q '^image-end$' "$events" && break ;;
        dso:archive)
            if grep -q '^archive-indexed$' "$events"; then
                settle=$((settle + 1))
                [ "$settle" -ge 10 ] && break
            fi ;;
        *:release) [ -e "$events.release" ] && break ;;
        *) break ;;
    esac
    sleep 0.1
    tenths=$((tenths + 1))
done
case "${TITAN_TEST_FAIL_LINK:-}" in
    "$kind"|both) status=86 ;;
esac
printf '%%s-end\n' "$kind" >> "$events"
exit "$status"
]]

local RANLIB_WRAPPER = [[#!/bin/sh
%s "$@"
status=$?
for argument in "$@"; do last=$argument; done
case "$last" in
    */output.a) [ "$status" -eq 0 ] && printf 'archive-indexed\n' >> %s ;;
esac
exit "$status"
]]

-- Records the provider pipeline's validation calls and injects a failure for
-- one `function:leaf` pair (TITAN_TEST_PROVIDER_FAIL).
local DRIVER_HOOK = [[
local log = os.getenv("TITAN_TEST_PROVIDER_LOG")
local fail = os.getenv("TITAN_TEST_PROVIDER_FAIL")
local subjects = {
    build_static_archive = 1,
    validate_library_image = 1,
    validate_titan_support = 1,
    validate_archive_library_equality = 2,
    validate_library_image_fresh = 1,
    publish_provider_bundle = 1,
}
local real_require = require
local hooked = false
function require(name)
    local module = real_require(name)
    if name == "titan-compiler.driver" and not hooked then
        hooked = true
        for field, index in pairs(subjects) do
            local original = module[field]
            module[field] = function(...)
                local leaf = tostring((select(index, ...))):match("([^/]+)$")
                local file = assert(io.open(log, "a"))
                file:write(field, " ", leaf, "\n")
                file:close()
                if fail == field .. ":" .. leaf then
                    return nil, "injected " .. field .. " failure for " .. leaf
                end
                return original(...)
            end
        end
    end
    return module
end
]]

local EXPECTED_VALIDATIONS = {
    "build_static_archive pkg.a",
    "validate_library_image pkg.so",
    "validate_archive_library_equality pkg.so",
    "validate_library_image_fresh pkg.so",
    "validate_library_image archive-validation.so",
    "validate_archive_library_equality archive-validation.so",
    "validate_library_image_fresh archive-validation.so",
    "publish_provider_bundle pkg.so",
}

describe("provider pair link pipeline", function()
    local workspace, source_root, output, events, validations, titanc_script

    -- A real parent GNU Make with a `+` recipe supplies the shared jobserver.
    local function make_jobs(slots, makefile)
        write_file(workspace .. "/parent.mk", makefile)
        return shell(workspace, "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL " ..
            "-u MAKEOVERRIDES -u GNUMAKEFLAGS make --no-print-directory -j" ..
            slots .. " -f parent.mk 2>&1")
    end

    local function titanc_command(environment, ...)
        local argv = {
            "env", "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5", "-u", "LUA_INIT_5_5",
            "-u", "TITAN_JOBS",
            "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_PATH_0_6=" .. workspace, "TITAN_PATH=",
            "PATH=" .. PREFIX .. "/bin:" .. (os.getenv("PATH") or "/usr/bin:/bin"),
            "CC=" .. workspace .. "/link-cc",
            "RANLIB=" .. workspace .. "/indexing-ranlib",
            "LUA_INIT=@" .. workspace .. "/driver-hook.lua",
            "TITAN_TEST_PROVIDER_LOG=" .. validations,
        }
        local names = {}
        for name in pairs(environment or {}) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            argv[#argv + 1] = name .. "=" .. environment[name]
        end
        if USE_CHECKOUT_COMPILER then
            for _, word in ipairs({
                "TITAN_ROCKS_ROOT=" .. PREFIX, LUA, "-e",
                string.format("package.path=%q..package.path",
                    REPO .. "/?.lua;" .. REPO .. "/?/init.lua;"),
                REPO .. "/titanc",
            }) do argv[#argv + 1] = word end
        else
            argv[#argv + 1] = INSTALLED_TITANC
        end
        for _, word in ipairs({ "--tree", source_root, "-o", output, ... }) do
            argv[#argv + 1] = word
        end
        return quote_words(argv)
    end

    -- Writes the titanc invocation used by both direct and Make-run builds.
    local function prepare_build(environment, ...)
        os.remove(events)
        os.remove(validations)
        write_file(titanc_script, "#!/bin/sh\nexec " ..
            titanc_command(environment, ...) .. "\n", true)
    end

    local function direct(environment, ...)
        prepare_build(environment, ...)
        return shell(workspace, "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL " ..
            quote(titanc_script) .. " 2>&1")
    end

    local function under_make(slots, environment, ...)
        prepare_build(environment, ...)
        return make_jobs(slots, "all:\n\t+@" .. titanc_script .. "\n")
    end

    local function write_module(answer)
        write_file(source_root .. "/pkg/left.titan",
            "function answer(): integer return " .. answer .. " end\n")
    end

    before_each(function()
        if platform.windows then return end
        workspace = assert(compiler_io.new_sync():tmpname())
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/src"
        output = workspace .. "/out"
        events = workspace .. "/events"
        validations = workspace .. "/validations"
        titanc_script = workspace .. "/titanc.sh"
        write_module(1)
        write_file(source_root .. "/pkg/right.titan",
            "function twice(n: integer): integer return n * 2 end\n")
        write_file(workspace .. "/link-cc", string.format(LINK_WRAPPER,
            quote(events), quote_words(configured_words(CC)),
            quote_words(configured_words(CC))), true)
        write_file(workspace .. "/indexing-ranlib", string.format(
            RANLIB_WRAPPER, quote_words(configured_words(RANLIB)),
            quote(events)), true)
        write_file(workspace .. "/driver-hook.lua", DRIVER_HOOK)
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
        workspace = nil
    end)

    local function assert_published()
        assert.equal("file", lfs.attributes(output .. "/pkg.so", "mode"))
        assert.equal("file", lfs.attributes(output .. "/pkg.a", "mode"))
        assert.same(EXPECTED_VALIDATIONS, lines(validations))
        local ok, result = shell(workspace, quote_words({
            "env", "-u", "LUA_PATH", "-u", "LUA_CPATH", "-u", "LUA_INIT",
            LUA, "-e", string.format(
                "package.path=%q..package.path package.cpath=%q..package.cpath " ..
                "assert(require('pkg.left').answer() + require('pkg.right').twice(2) > 0)",
                output .. "/?.lua;", output .. "/?.so;" .. REPO .. "/?.so;"),
        }) .. " 2>&1")
        assert.truthy(ok, result)
    end

    it("keeps both links serial and orders a single-slot pipeline", function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local ok, result = direct({}, "--jobs", "1", "pkg.left", "pkg.right")
        assert.truthy(ok, result)
        assert_published()
        assert.same({
            "dso-start", "dso-end", "archive-indexed", "image-start", "image-end",
        }, lines(events))
    end)

    it("builds the archive during the DSO link but never overlaps links without a jobserver",
       function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local ok, result = direct({ TITAN_TEST_LINK_HOLD = "archive" },
            "--jobs", "4", "pkg.left", "pkg.right")
        assert.truthy(ok, result)
        assert_published()
        assert.same({
            "dso-start", "archive-indexed", "dso-end", "image-start", "image-end",
        }, lines(events))
    end)

    it("runs the archive-backed link concurrently only with a granted jobserver slot",
       function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local _, uname = shell(workspace, "uname -s")
        if not uname:match("Linux") then
            pending("usable shared jobserver transport with the host GNU Make")
            return
        end
        -- Two slots: the recipe's implicit slot runs the DSO link and the one
        -- borrowed token runs the archive-backed link.
        local ok, result = under_make(2, { TITAN_TEST_LINK_HOLD = "image" },
            "--verbose", "--jobs", "4", "pkg.left", "pkg.right")
        assert.truthy(ok, result)
        assert.falsy(result:lower():find("jobserver", 1, true), result)
        assert_published()
        local trace = lines(events)
        assert.truthy(position(trace, "image-start") <
            position(trace, "dso-end"), table.concat(trace, " "))
        -- Each link command is announced once, the DSO's first.
        local link_commands = {}
        for line in result:gmatch("[^\n]+") do
            if line:find("'-shared'", 1, true) then
                link_commands[#link_commands + 1] = line
            end
        end
        assert.equal(2, #link_commands, result)
        assert.truthy(link_commands[1]:find(".stage.tmp.", 1, true) and
            link_commands[1]:find("/pkg.so'", 1, true), result)
        assert.truthy(link_commands[2]:find("/archive-validation.so'", 1, true),
            result)

        -- With the only token held by a sibling recipe, the image link waits
        -- for the DSO link's slot instead of exceeding the shared cap.
        write_module(2)
        prepare_build({ TITAN_TEST_LINK_HOLD = "archive" },
            "--jobs", "4", "pkg.left", "pkg.right")
        ok, result = make_jobs(2, table.concat({
            "all: provider blocker",
            "provider:",
            "\t+@n=0; while [ ! -e blocker-started ] && [ $$n -lt 600 ]; do sleep 0.1; n=$$((n + 1)); done; " ..
                titanc_script,
            "blocker:",
            "\t@touch blocker-started; n=0; while ! grep -q '^dso-end$$' events 2>/dev/null && [ $$n -lt 600 ]; do sleep 0.1; n=$$((n + 1)); done",
            "",
        }, "\n"))
        assert.truthy(ok, result)
        assert_published()
        assert.same({
            "dso-start", "archive-indexed", "dso-end", "image-start", "image-end",
        }, lines(events))
    end)

    it("publishes nothing and leaves no staged siblings when either path fails",
       function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local _, uname = shell(workspace, "uname -s")
        local shared = uname:match("Linux") ~= nil
        local ok, result = direct({}, "--incremental", "pkg.left", "pkg.right")
        assert.truthy(ok, result)
        local inventory = provider_artifacts(output, true)
        local published = {}
        for _, leaf in ipairs({ "pkg.so", "pkg.a" }) do
            published[leaf] = {
                bytes = read_file(output .. "/" .. leaf),
                modified = lfs.attributes(output .. "/" .. leaf, "modification"),
            }
        end
        -- A successful rebuild would publish different bytes.
        write_module(7)
        local cases = {
            { link = "dso", hold = "image",
              message = "failed to link library 'pkg' (exit, 86)" },
            { link = "image", hold = "image",
              message = "failed to link archive validation image 'pkg' (exit, 86)" },
            { validation = "validate_library_image_fresh:pkg.so", hold = "image",
              message = "injected validate_library_image_fresh failure for pkg.so" },
            { validation = "validate_archive_library_equality:archive-validation.so",
              hold = "image",
              message = "injected validate_archive_library_equality failure for archive-validation.so" },
            { validation = "build_static_archive:pkg.a",
              message = "failed to build static provider 'pkg': injected build_static_archive failure for pkg.a" },
        }
        for _, mode in ipairs({ "serial", "overlap" }) do
            if mode == "overlap" and not shared then break end
            for _, case in ipairs(cases) do
                local environment = {
                    TITAN_TEST_FAIL_LINK = case.link,
                    TITAN_TEST_PROVIDER_FAIL = case.validation,
                    TITAN_TEST_LINK_HOLD = mode == "overlap" and case.hold or nil,
                }
                if mode == "serial" then
                    ok, result = direct(environment, "--incremental",
                        "--jobs", "1", "pkg.left", "pkg.right")
                else
                    ok, result = under_make(2, environment, "--incremental",
                        "--jobs", "4", "pkg.left", "pkg.right")
                end
                local label = mode .. " " .. (case.link or case.validation)
                assert.falsy(ok, label .. ": " .. result)
                assert.truthy(result:find(case.message, 1, true),
                    label .. ": " .. result)
                assert.falsy(result:lower():find("jobserver", 1, true), result)
                local trace = lines(events)
                if mode == "overlap" and case.hold then
                    -- The failure arrived while the other link was running.
                    assert.truthy(position(trace, "image-start") <
                        position(trace, "dso-end"), label)
                end
                -- Every started link was drained before titanc returned.
                assert.equal(position(trace, "image-start") ~= nil,
                    position(trace, "image-end") ~= nil, label)
                assert.truthy(position(trace, "dso-end"), label)
                assert.falsy(position(lines(validations),
                    "publish_provider_bundle pkg.so"), label)
                assert.same(inventory, provider_artifacts(output, false), label)
                for leaf, snapshot in pairs(published) do
                    assert.equal(snapshot.bytes, read_file(output .. "/" .. leaf), label)
                    assert.equal(snapshot.modified, lfs.attributes(
                        output .. "/" .. leaf, "modification"), label)
                end
            end
        end
    end)

    -- No staged provider sibling, archive stage, or captured-output file.
    local function assert_no_temporaries(label)
        for _, entry in ipairs(listing(output)) do
            assert.falsy(entry:find(".stage.tmp.", 1, true) or
                entry:find(".archive-stage.", 1, true) or
                entry:find(".titan-temporary", 1, true) or
                entry:find("archive-validation", 1, true), label .. ": " .. entry)
        end
        assert.is_nil(lfs.attributes(output .. "/pkg.so"), label)
        assert.is_nil(lfs.attributes(output .. "/pkg.a"), label)
    end

    it("reports the earlier pipeline failure when the later link fails first",
       function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local _, uname = shell(workspace, "uname -s")
        if not uname:match("Linux") then
            pending("usable shared jobserver transport with the host GNU Make")
            return
        end
        -- The archive-backed link fails and finishes while the DSO link is
        -- still held open; the DSO link or its validation then fails.
        for _, case in ipairs({
            { environment = { TITAN_TEST_FAIL_LINK = "both" },
              message = "failed to link library 'pkg' (exit, 86)" },
            { environment = {
                  TITAN_TEST_FAIL_LINK = "image",
                  TITAN_TEST_PROVIDER_FAIL = "validate_library_image_fresh:pkg.so",
              },
              message = "injected validate_library_image_fresh failure for pkg.so" },
        }) do
            case.environment.TITAN_TEST_LINK_HOLD = "image-end"
            local ok, result = under_make(2, case.environment,
                "--jobs", "4", "pkg.left", "pkg.right")
            assert.falsy(ok, result)
            assert.truthy(result:find(case.message, 1, true), result)
            assert.falsy(result:find("archive validation image", 1, true), result)
            local trace = lines(events)
            assert.truthy(position(trace, "image-end") <
                position(trace, "dso-end"), table.concat(trace, " "))
            assert_no_temporaries(case.message)
        end
    end)

    it("drains live links, cleans up, and re-raises an interrupt", function()
        if platform.windows then pending("Unix paired provider pipeline"); return end
        local _, uname = shell(workspace, "uname -s")
        local cases = {
            { mode = "serial", signal = "TERM", number = 15 },
            { mode = "serial", signal = "HUP", number = 1 },
            -- The restored SIGINT action is the Lua interpreter's
            -- `interrupted!` error rather than signal termination.
            { mode = "serial", signal = "INT", status = 1,
              message = "interrupted!" },
        }
        if uname:match("Linux") then
            cases[#cases + 1] = { mode = "overlap", signal = "TERM", number = 15 }
        end
        for _, case in ipairs(cases) do
            local label = case.mode .. " " .. case.signal
            remove_tree(output)
            os.remove(events .. ".release")
            local wait_links, start
            if case.mode == "serial" then
                prepare_build({ TITAN_TEST_LINK_HOLD = "release" },
                    "--jobs", "1", "pkg.left", "pkg.right")
                start = quote(titanc_script) .. " > run.out 2>&1 & " ..
                    "runner=$!; echo $runner > titanc.pid; "
                wait_links = "dso-start"
            else
                prepare_build({ TITAN_TEST_LINK_HOLD = "release" },
                    "--jobs", "4", "pkg.left", "pkg.right")
                write_file(workspace .. "/parent.mk",
                    "all:\n\t+@" .. titanc_script ..
                    " & echo $$! > titanc.pid; wait $$!\n")
                start = "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL " ..
                    "-u MAKEOVERRIDES -u GNUMAKEFLAGS make --no-print-directory " ..
                    "-j2 -f parent.mk > run.out 2>&1 & runner=$!; "
                wait_links = "image-start"
            end
            local ok, result = shell(workspace, "rm -f titanc.pid; " .. start ..
                "n=0; while ! grep -q '^" .. wait_links .. "$' " ..
                quote(events) .. " 2>/dev/null && [ $n -lt 600 ]; do " ..
                "sleep 0.1; n=$((n + 1)); done; sleep 0.3; " ..
                "kill -" .. case.signal .. " $(cat titanc.pid); sleep 0.5; " ..
                "touch " .. quote(events .. ".release") .. "; " ..
                "wait $runner; echo \"status=$?\"; cat run.out")
            assert.truthy(ok, result)
            local trace = lines(events)
            -- Every started link ran to completion before titanc exited.
            assert.truthy(position(trace, "dso-end"), label .. ": " .. result)
            assert.equal(position(trace, "image-start") ~= nil,
                position(trace, "image-end") ~= nil, label)
            if case.mode == "serial" then
                assert.truthy(result:find("status=" ..
                    (case.status or 128 + case.number), 1, true),
                    label .. ": " .. result)
                assert.truthy(result:find(case.message or "", 1, true),
                    label .. ": " .. result)
            else
                assert.truthy(position(trace, "image-start"), label)
                assert.truthy(result:find("Error " .. (128 + case.number), 1,
                    true), label .. ": " .. result)
                assert.falsy(result:lower():find("jobserver", 1, true), result)
            end
            assert.falsy(position(lines(validations),
                "publish_provider_bundle pkg.so"), label)
            assert_no_temporaries(label)
        end
    end)
end)

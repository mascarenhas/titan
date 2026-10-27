local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local publication = require "titan-compiler.windows_publication"
local temporary = require "spec.support.temporary"

local function write(path, bytes) assert(compiler_io.new_sync():write_file(path, bytes)) end
local function read(path) return assert(compiler_io.new_sync():read_file(path)) end
local function remove(path)
    local kind = lfs.symlinkattributes(path, "mode")
    if kind == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif kind then assert(os.remove(path)) end
end

describe("Windows executable output-set publication", function()
    local root, fs, request, marker
    local function predecessor()
        assert.equal("old DLL", read(request.provider.destination))
        assert.equal("old EXE", read(request.executable.destination))
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        marker = root .. "/link-record"
        request = { provider = { source = root .. "/staged.dll", destination = root .. "/app.dll" },
            executable = { source = root .. "/staged.exe", destination = root .. "/app.exe" } }
        write(request.provider.source, "new DLL"); write(request.executable.source, "new EXE")
        write(request.provider.destination, "old DLL"); write(request.executable.destination, "old EXE")
        write(marker, "old successful link")
        local sequence = 0
        local io = compiler_io.new_sync()
        fs = {
            stat = function(path)
                local stat, err = io:lstat(path)
                return stat, err, not stat and not err and 2 or nil
            end,
            reserve = function(path)
                sequence = sequence + 1
                local reserved = path .. ".reserved." .. sequence
                write(reserved, "")
                return reserved
            end,
            replace = function(from, to) return io:rename(from, to) end,
            remove = os.remove,
        }
    end)
    after_each(function() remove(root) end)

    it("invalidates the success marker before either image changes and commits the EXE last", function()
        assert(publication.publish_program(request, fs, {
            before_commit = function()
                predecessor()
                return os.remove(marker)
            end,
            after_commit = function(index)
                assert.is_nil(lfs.attributes(marker))
                assert.equal("new DLL", read(request.provider.destination))
                assert.equal(index == 1 and "old EXE" or "new EXE", read(request.executable.destination))
                return true
            end,
        }))
        assert.equal("new EXE", read(request.executable.destination))
    end)

    it("restores the DLL when the selected executable destination cannot be replaced", function()
        local replace = fs.replace
        fs.replace = function(from, to)
            if to == request.executable.destination then return nil, "EXE is in use" end
            return replace(from, to)
        end
        local ok, err = publication.publish_program(request, fs, {
            before_commit = function() return os.remove(marker) end,
        })
        assert.is_nil(ok)
        assert.matches("EXE is in use", err, 1, true)
        predecessor()
        assert.is_nil(lfs.attributes(marker))
    end)

    it("does not mutate either predecessor if marker invalidation fails", function()
        local ok, err = publication.publish_program(request, fs, {
            before_commit = function() return nil, "cannot invalidate certificate" end,
        })
        assert.is_nil(ok)
        assert.matches("cannot invalidate certificate", err, 1, true)
        predecessor()
        assert.equal("old successful link", read(marker))
    end)

    it("rolls back the complete set at each caught commit boundary", function()
        for failure = 1, 2 do
            local ok, err = publication.publish_program(request, fs, {
                after_commit = function(index)
                    if index == failure then return nil, "injected boundary failure" end
                    return true
                end,
            })
            assert.is_nil(ok)
            assert.matches("injected boundary failure", err, 1, true)
            predecessor()
        end
    end)

    it("rejects duplicate destinations before changing either image", function()
        request.executable.destination = request.provider.destination
        local ok, err = publication.publish_program(request, fs)
        assert.is_nil(ok)
        assert.matches("duplicate publication destination", err, 1, true)
        assert.equal("old DLL", read(request.provider.destination))
    end)
end)

describe("output-domain process coordination", function()
    local root, frontend, lua, repository
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        repository = assert(lfs.currentdir())
        local prefix = require("spec.support.installed_prefix").active()
        lua = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")
        frontend = root .. "/lock-child.lua"
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
local build = require "titan-compiler.build"
local directories = {}
for index = 2, #arg do directories[#directories + 1] = arg[index] end
local locks, err = build.lock_outputs(require("titan-compiler.io").new_sync(), directories, {verbose=true})
if not locks then io.stderr:write(err, "\n"); os.exit(1) end
io.stdout:write("acquired\n"); io.stdout:flush()
if arg[1] == "hold" then io.read("*l") end
assert(locks:release() ~= false)
io.stdout:write("released\n"); io.stdout:flush()
]], repository, repository, platform.windows and ".dll" or ".so"))
    end)
    after_each(function() remove(root) end)

    local function contend(lua_path, script, holder_directories, waiter_directories, terminate, options)
        options = options or {}
        local uv = require("titan-compiler.process").library()
        local children, events, failures = {}, {}, {}
        local deadline, readiness = uv.new_timer()
        local environment
        if options.env then
            local values = uv.os_environ()
            for key, value in pairs(options.env) do values[key] = value end
            environment = {}
            for key, value in pairs(values) do environment[#environment + 1] = key .. "=" .. value end
        end
        local waiter_started, holder_released = false, false
        local spawn, holder
        local function close(handle)
            if handle and not handle:is_closing() then handle:close() end
        end
        local function release_holder()
            holder_released = true
            if options.release_orphan then options.release_orphan()
            elseif terminate then assert(holder.process:kill("sigkill"))
            else assert(holder.input:write("release\n")) end
        end
        spawn = function(role, mode, directories)
            local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
            local child = { input = stdin, output = stdout, errors = stderr, role = role }
            local arguments = { "-E", script, mode }
            for _, directory in ipairs(directories) do arguments[#arguments + 1] = directory end
            local cwd = (role == "holder" and options.holder_cwd or options.waiter_cwd) or options.cwd
            child.process = assert(uv.spawn(lua_path, { args = arguments,
                env = environment, cwd = cwd, stdio = { stdin, stdout, stderr } },
                function(code, signal)
                    child.code, child.signal, child.exited = code, signal, true
                    events[#events + 1] = role .. ":exit"
                    close(child.process); close(stdin)
                    if role == "holder" then close(readiness) end
                    if role == "holder" and options.defer_waiter and not waiter_started then
                        waiter_started = true
                        if options.after_holder_exit then
                            local ok, err = pcall(options.after_holder_exit)
                            if not ok then failures[#failures + 1] = tostring(err) end
                        end
                        spawn("waiter", "once", waiter_directories)
                    elseif role == "waiter" and options.after_waiter_exit then
                        local ok, err = pcall(options.after_waiter_exit)
                        if not ok then failures[#failures + 1] = tostring(err) end
                    end
                end))
            children[#children + 1] = child
            local function consume(pipe)
                local pending = ""
                pipe:read_start(function(err, bytes)
                    if err then failures[#failures + 1] = tostring(err) end
                    if not bytes then close(pipe); return end
                    pending = pending .. bytes:gsub("\r\n", "\n")
                    while true do
                        local finish = pending:find("\n", 1, true)
                        if not finish then break end
                        local line = pending:sub(1, finish - 1)
                        pending = pending:sub(finish + 1)
                        events[#events + 1] = role .. ":" .. line
                        if role == "holder" and line == "acquired" and not waiter_started then
                            if options.defer_waiter then assert(holder.process:kill("sigkill"))
                            else
                                waiter_started = true
                                spawn("waiter", "once", waiter_directories)
                            end
                        elseif role == "waiter" and line:find("waiting for build lock", 1, true) and not holder_released then
                            release_holder()
                        elseif role == "waiter" and line == "acquired" and not holder_released then
                            if options.allow_early_waiter and options.allow_early_waiter() then
                                holder_released = true
                            else
                                failures[#failures + 1] = "waiter acquired an owned output domain"
                                release_holder()
                            end
                        end
                    end
                end)
            end
            consume(stdout); consume(stderr)
            return child
        end
        holder = spawn("holder", "hold", holder_directories)
        if options.holder_ready_path then
            assert.is_true(options.defer_waiter)
            readiness = uv.new_timer()
            readiness:start(0, 5, function()
                local marker = io.open(options.holder_ready_path, "rb")
                if marker then
                    marker:close()
                    close(readiness)
                    events[#events + 1] = "holder:acquired"
                    assert(holder.process:kill("sigkill"))
                end
            end)
        end
        deadline:start(options.timeout or 15000, 0, function()
            failures[#failures + 1] = "output lock subprocess deadline"
            close(readiness)
            if options.release_orphan then pcall(options.release_orphan) end
            for _, child in ipairs(children) do
                if not child.exited then child.process:kill("sigkill") end
            end
        end)
        -- Process/pipe closure drives completion; the timer is unreferenced so
        -- it cannot keep a successfully drained controller alive.
        deadline:unref()
        uv.run()
        close(deadline)
        close(readiness)
        uv.run("nowait")
        assert.same({}, failures, table.concat(events, "\n"))
        assert.is_true(holder_released, table.concat(events, "\n"))
        assert.equal(2, #children, table.concat(events, "\n"))
        assert.equal(0, children[2].code, table.concat(events, "\n"))
        if not terminate then
            assert.equal(0, children[1].code, table.concat(events, "\n"))
        elseif options.defer_waiter then
            assert.equal(9, children[1].signal, table.concat(events, "\n"))
        end
        return events
    end

    local function compiler_environment(extra)
        local prefix = require("spec.support.installed_prefix").active()
        local values = {
            TITAN_ROCKS_ROOT = prefix, TITAN_RUNTIME_PREBUILT = "1", CCACHE_DISABLE = "1",
            TITAN_PROBE_CACHE_DISABLE = "1", TITAN_EXTRA_CPPFLAGS = "",
            TITAN_EXTRA_CFLAGS = "-O0 -fno-lto", TITAN_EXTRA_LDFLAGS = "-fno-lto",
            PATH = prefix .. "/bin" .. (platform.windows and ";" or ":") .. (os.getenv("PATH") or ""),
        }
        for key, value in pairs(extra or {}) do values[key] = value end
        return values
    end

    it("serializes two processes sharing an output tree", function()
        local output = root .. "/build Ω"
        contend(lua, frontend, { output }, { output })
        assert.equal("file", lfs.symlinkattributes(output .. "/.titan-build.lock", "mode"))
    end)

    it("releases ownership after holder death without deleting the lock file", function()
        local output = root .. "/build"
        contend(lua, frontend, { output }, { output }, true)
        assert.equal("file", lfs.symlinkattributes(output .. "/.titan-build.lock", "mode"))
    end)

    it("converges physical directory aliases and deduplicates a repeated domain", function()
        if platform.windows then pending("POSIX directory symlink fixture"); return end
        local output, alias = root .. "/build", root .. "/alias"
        assert(lfs.mkdir(output))
        assert(lfs.link(output, alias, true))
        contend(lua, frontend, { output, alias }, { alias, output })
    end)

    it("orders external executable and object domains consistently", function()
        local output, external = root .. "/build", root .. "/external"
        contend(lua, frontend, { output, external }, { external, output })
    end)

    it("serializes application and test invocations sharing production objects", function()
        local output = root .. "/shared-output"
        local prefix = require("spec.support.installed_prefix").active()
        write(root .. "/shared.titan", "function value(): integer return 7 end\n")
        write(root .. "/app.titan", 'local shared = import "shared"\nfunction main(args: {string}): integer return shared.value() - 7 end\n')
        write(root .. "/checks.titan", 'local shared = import "shared"\nlocal test = import "test"\nfunction test_value(context: test.Context) test.assert(shared.value() == 7) end\n')
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
local hold, output = arg[1] == "hold", arg[2]
local build = require "titan-compiler.build"
local run = build.run
build.run = function(...)
    io.stdout:write("acquired\n"); io.stdout:flush()
    if hold then io.read("*l") end
    return run(...)
end
arg = { [0] = %q .. "/titanc", "-v", "--incremental", "--tree", %q, "--output", output,
    "--exe", %q .. (hold and "/application" or "/tests"), hold and "app" or "checks" }
if not hold then arg[#arg + 1] = "--test" end
dofile(%q .. "/titanc")
]], repository, repository, platform.windows and ".dll" or ".so", repository, root, root, repository))
        contend(lua, frontend, { output }, { output }, false, { timeout = 60000, env = {
            TITAN_ROCKS_ROOT = prefix, TITAN_RUNTIME_PREBUILT = "1", CCACHE_DISABLE = "1",
            TITAN_PROBE_CACHE_DISABLE = "1", TITAN_EXTRA_CPPFLAGS = "",
            TITAN_EXTRA_CFLAGS = "-O0 -fno-lto", TITAN_EXTRA_LDFLAGS = "-fno-lto",
        } })
        assert.equal("file", lfs.attributes(output .. "/shared.o", "mode"))
        for _, name in ipairs({ "application", "tests" }) do
            assert.equal("file", lfs.attributes(root .. "/" .. name .. (platform.windows and ".exe" or ""), "mode"))
        end
    end)

    it("coordinates a selected source root beyond the first no-output search root", function()
        local first, shared = root .. "/first", root .. "/shared"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(shared))
        local holder_cwd, waiter_cwd = root .. "/holder-cwd", root .. "/waiter-cwd"
        assert(lfs.mkdir(holder_cwd)); assert(lfs.mkdir(waiter_cwd))
        write(shared .. "/leaf.titan", "function value(): integer return 7 end\n")
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
local hold = arg[1] == "hold"
local build = require "titan-compiler.build"
local run = build.run
build.run = function(...)
    io.stdout:write("acquired\n"); io.stdout:flush()
    if hold then io.read("*l") end
    return run(...)
end
arg = { [0] = %q .. "/titanc", "-v", "--incremental", "-c", "--tree",
    hold and %q or %q, "leaf" }
dofile(%q .. "/titanc")
]], repository, repository, platform.windows and ".dll" or ".so",
            repository, first .. ";" .. shared, shared, repository))
        contend(lua, frontend, {}, {}, false, { timeout = 60000, env = compiler_environment(),
            holder_cwd = holder_cwd, waiter_cwd = waiter_cwd })
        assert.equal("file", lfs.attributes(shared .. "/leaf.o", "mode"))
    end)

    it("coordinates default executables for distinct source trees in one working directory", function()
        local first, second, cwd = root .. "/first", root .. "/second", root .. "/cwd"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(second)); assert(lfs.mkdir(cwd))
        write(first .. "/app.titan", "function main(args: {string}): integer return 11 end\n")
        write(second .. "/app.titan", "function main(args: {string}): integer return 22 end\n")
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
local hold = arg[1] == "hold"
local build = require "titan-compiler.build"
local run = build.run
build.run = function(...)
    io.stdout:write("acquired\n"); io.stdout:flush()
    if hold then io.read("*l") end
    return run(...)
end
arg = { [0] = %q .. "/titanc", "-v", "--incremental", "--tree",
    hold and %q or %q, "app" }
dofile(%q .. "/titanc")
]], repository, repository, platform.windows and ".dll" or ".so", repository, first, second, repository))
        contend(lua, frontend, {}, {}, false, { timeout = 60000, cwd = cwd, env = compiler_environment() })
        local executable = cwd .. (platform.windows and "/bin/app.exe" or "/app")
        assert.equal("file", lfs.attributes(executable, "mode"))
    end)

    local function synthetic_phase_contention(phase)
        if platform.windows then pending("POSIX synthetic compiler lifetime"); return end
        root = assert(compiler_io.new_sync():realpath(root))
        local first, second, output = root .. "/first", root .. "/second", root .. "/objects"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(second))
        local is_test = phase ~= "program-entrypoint"
        if is_test then
            write(first .. "/app.titan", [[
local test = import "test"
local timer = import "timer"
function test_held(context: test.Context) test.assert(false) end
]])
            write(second .. "/app.titan", [[
local test = import "test"
local timer = import "timer"
function test_current(context: test.Context) test.assert(true) end
]])
        else
            write(first .. "/app.titan", [[
local timer = import "timer"
function main(args: {string}): integer return 11 end
]])
            write(second .. "/app.titan", [[
local timer = import "timer"
function main(args: {string}): integer return 22 end
]])
        end
        local executable, release = root .. "/shared-image", root .. "/release-native"
        local stage_log, wrapper = root .. "/native-object", root .. "/synthetic-cc"
        local cdriver = require "c-parser.cdriver"
        local function quote(value) return assert(cdriver.shell_quote(value)) end
        local words = assert(cdriver.split_shell_words(require("titan-compiler.driver").CC))
        if words[1] == "exec" then table.remove(words, 1) end
        local real = {}
        for _, word in ipairs(words) do real[#real + 1] = quote(word) end
        real = table.concat(real, " ")
        local pattern = phase == "runner" and "*__test_runner.c|*__test_runner.part*.c" or
            phase == "test-entrypoint" and "*__test_entrypoint.c" or "*__entrypoint.c"
        write(wrapper, string.format([[#!/bin/sh
compile=no
selected=no
output=
next=no
for argument in "$@"; do
    case "$argument" in -c) compile=yes ;; esac
    case "$argument" in %s) selected=yes ;; esac
    if [ "$next" = yes ]; then output=$argument; next=no
    elif [ "$argument" = -o ]; then next=yes; fi
done
if [ "$compile" = yes ] && [ "$selected" = yes ] && mkdir %s 2>/dev/null; then
    printf '%%s' "$output" > %s
    %s
    attempts=0
    while [ ! -e %s ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 800 ] || exit 97
        sleep 0.05
    done
    %s "$@"
    status=$?
    printf 'native-done\n'
    exit "$status"
fi
exec %s "$@"
]], pattern, quote(root .. "/claimed-native"), quote(stage_log),
            phase == "runner" and ":" or "printf 'acquired\\n'",
            quote(release), real, real))
        assert(compiler_io.new_sync():run({ "chmod", "u+x", wrapper }).ok)
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?.so;" .. package.cpath
local hold = arg[1] == "hold"
local phase = %q
require("titan-compiler.coder").DEFAULT_SPLIT_THRESHOLD = 1
if hold and phase == "runner" then
    local jobs = require "titan-compiler.jobs"
    local launch, announced = jobs.launch, false
    jobs.launch = function(channel, argv, ...)
        local child, err = launch(channel, argv, ...)
        if child and not announced then
            for _, argument in ipairs(argv) do
                if argument:match("__test_runner[.]c$") or
                   argument:match("__test_runner[.]part[0-9]+[.]c$") then
                    announced = true
                    io.stdout:write("acquired\n"); io.stdout:flush()
                    break
                end
            end
        end
        return child, err
    end
elseif not hold then
    local build = require "titan-compiler.build"
    local run = build.run
    build.run = function(...)
        io.stdout:write("acquired\n"); io.stdout:flush()
        return run(...)
    end
end
arg = { [0] = %q .. "/titanc", "-v", "--incremental",
    "--jobs", phase == "runner" and "2" or "1",
    "--c-parts", phase == "runner" and "2" or "1",
    "--tree", hold and %q or %q, "--output", %q, "--exe", %q }
if not hold then arg[#arg + 1] = "--no-uv-bootstrap" end
if %s then arg[#arg + 1] = "--test" end
arg[#arg + 1] = "app"
dofile(%q .. "/titanc")
]], repository, repository, phase, repository, first, second, output, executable,
            tostring(is_test), repository))
        local function snapshot()
            local files = { [executable] = read(executable) }
            local function visit(directory)
                for name in lfs.dir(directory) do
                    if name ~= "." and name ~= ".." then
                        local filename = directory .. "/" .. name
                        if lfs.symlinkattributes(filename, "mode") == "directory" then visit(filename)
                        else files[filename] = read(filename) end
                    end
                end
            end
            visit(output .. "/.titan-links")
            return files
        end
        local successor_files
        local function release_native() write(release, "release") end
        contend(lua, frontend, {}, {}, true, {
            timeout = 60000, defer_waiter = true,
            env = compiler_environment({ CC = wrapper }),
            after_holder_exit = function()
                local lock = assert(require("titan")._output_lock_open(output .. "/.titan-build.lock"))
                local held, err = lock:try()
                lock:close()
                assert.is_false(held, tostring(err))
            end,
            release_orphan = release_native,
            after_waiter_exit = function()
                local captured, capture_error = pcall(function() successor_files = snapshot() end)
                release_native()
                assert.is_true(captured, tostring(capture_error))
            end,
        })
        assert.same(successor_files, snapshot())
        assert.matches("/.titan-links/", read(stage_log), 1, true)
        if phase == "runner" then
            local split
            for filename in pairs(successor_files) do
                if filename:match("__test_runner[.]part1[.]o$") then split = true end
            end
            assert.is_true(split, "the runner must exercise the local parallel native batch")
        end
        local result = compiler_io.new_sync():run({ executable })
        assert.equal(is_test and 0 or 22, result.status, result.output or result.diagnostic)
    end

    it("retains the output lease for a killed standalone entrypoint compiler", function()
        synthetic_phase_contention("program-entrypoint")
    end)

    it("retains the output lease for a killed test entrypoint compiler", function()
        synthetic_phase_contention("test-entrypoint")
    end)

    it("retains output leases through a killed coordinator's parallel runner batch", function()
        synthetic_phase_contention("runner")
    end)

    it("retains output leases for an orphaned C-only preprocessing writer", function()
        if platform.windows then pending("POSIX captured compiler lifetime"); return end
        root = assert(compiler_io.new_sync():realpath(root))
        local source, output = root .. "/native.c", root .. "/objects"
        local ready, release = root .. "/native-ready", root .. "/release-native"
        local wrapper, stage_log = root .. "/captured-cc", root .. "/native-stages"
        write(source, "int native_value(void) { return NATIVE_VALUE; }\n")
        local cdriver = require "c-parser.cdriver"
        local function quote(value) return assert(cdriver.shell_quote(value)) end
        local words = assert(cdriver.split_shell_words(require("titan-compiler.driver").CC))
        if words[1] == "exec" then table.remove(words, 1) end
        local real = {}
        for _, word in ipairs(words) do real[#real + 1] = quote(word) end
        real = table.concat(real, " ")
        write(wrapper, string.format([[#!/bin/sh
preprocess=no
selected=no
output=
dependencies=
next=
for argument in "$@"; do
    case "$argument" in -E) preprocess=yes ;; %s) selected=yes ;; esac
    if [ "$next" = output ]; then output=$argument; next=
    elif [ "$next" = dependencies ]; then dependencies=$argument; next=
    elif [ "$argument" = -o ]; then next=output
    elif [ "$argument" = -MF ]; then next=dependencies; fi
done
if [ "$preprocess" = yes ] && [ "$selected" = yes ] && mkdir %s 2>/dev/null; then
    printf '%%s\n%%s\n' "$output" "$dependencies" > %s
    %s "$@" || exit $?
    printf 'ready' > %s
    mv %s %s
    attempts=0
    while [ ! -e %s ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 800 ] || exit 97
        sleep 0.05
    done
fi
exec %s "$@"
]], quote(source), quote(root .. "/claimed-native"), quote(stage_log), real,
            quote(ready .. ".tmp"), quote(ready .. ".tmp"), quote(ready), quote(release), real))
        assert(compiler_io.new_sync():run({ "chmod", "u+x", wrapper }).ok)
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?.so;" .. package.cpath
local hold = arg[1] == "hold"
if not hold then
    local driver = require "titan-compiler.driver"
    local preflight = driver.preflight_build_outputs
    driver.preflight_build_outputs = function(...)
        local ok, err = preflight(...)
        if ok then io.stdout:write("acquired\n"); io.stdout:flush() end
        return ok, err
    end
end
arg = { [0] = %q .. "/titanc", "-v", "-c", "--incremental", "--print-c-objects",
    "--output", %q, "--c-source", %q, "--define", hold and "NATIVE_VALUE=11" or "NATIVE_VALUE=22" }
dofile(%q .. "/titanc")
]], repository, repository, repository, output, source, repository))
        local function snapshot()
            local files = {}
            for name in lfs.dir(output .. "/.native") do
                if name ~= "." and name ~= ".." then
                    local filename = output .. "/.native/" .. name
                    files[filename] = read(filename)
                end
            end
            return files
        end
        local successor_files
        local events = contend(lua, frontend, {}, {}, true, {
            timeout = 60000, defer_waiter = true, holder_ready_path = ready,
            env = compiler_environment({ CC = wrapper }),
            after_holder_exit = function()
                local lock = assert(require("titan")._output_lock_open(output .. "/.titan-build.lock"))
                local held, err = lock:try()
                lock:close()
                assert.is_false(held, tostring(err))
            end,
            release_orphan = function() write(release, "release") end,
            after_waiter_exit = function() successor_files = snapshot() end,
        })
        assert.same(successor_files, snapshot())
        local preprocessed, dependencies = read(stage_log):match("^([^\n]+)\n([^\n]+)\n$")
        assert.matches("/.native/", preprocessed, 1, true)
        assert.matches("/.native/", dependencies, 1, true)
        assert.matches("return 22", read(preprocessed), 1, true)
        local object
        for _, event in ipairs(events) do
            local filename = event:match("^waiter:(/.+[.]o)$")
            if filename then assert.is_nil(object); object = filename end
        end
        assert.is_string(object, table.concat(events, "\n"))
        assert.is_string(successor_files[object:gsub("[.]o$", ".record")])
        local consumer, executable = root .. "/consumer.c", root .. "/native-image"
        write(consumer, "int native_value(void); int main(void) { return native_value(); }\n")
        local argv = {}
        for _, word in ipairs(words) do argv[#argv + 1] = word end
        for _, word in ipairs({ consumer, object, "-o", executable }) do argv[#argv + 1] = word end
        local linked = compiler_io.new_sync():run(argv)
        assert.is_true(linked.ok, linked.output or linked.diagnostic)
        local ran = compiler_io.new_sync():run({ executable })
        assert.equal(22, ran.status, ran.output or ran.diagnostic)
    end)

    it("preflights lock and metadata destinations for ordinary and AST builds", function()
        local source, output = root .. "/source", root .. "/objects"
        assert(lfs.mkdir(source))
        write(source .. "/app.titan", "function main(args: {string}): integer return 0 end\n")
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?" .. %q .. ";" .. package.cpath
dofile(%q .. "/titanc")
]], repository, repository, platform.windows and ".dll" or ".so", repository))
        local function compile(extra, print_ast)
            local argv = { lua, "-E", frontend, print_ast and "--print-ast" or "--incremental",
                "--tree", source, "--output", output, "--c-parts", "1", "--jobs", "1" }
            for _, argument in ipairs(extra) do argv[#argv + 1] = argument end
            argv[#argv + 1] = "app"
            return compiler_io.new_sync():run(argv, {
                env = compiler_environment(), stderr_to_stdout = true,
            })
        end
        local initial = compile({ "-c" })
        assert.is_true(initial.ok, initial.output or initial.diagnostic)
        local lock = output .. "/.titan-build.lock"
        local lock_info = assert(lfs.attributes(lock))
        local lock_bytes, c_bytes, object_bytes = read(lock), read(output .. "/app.c"), read(output .. "/app.o")
        local destinations = {}
        if not platform.windows then
            destinations[#destinations + 1] = lock
            local alias = output .. "/lock-image"
            assert(lfs.link(lock, alias))
            destinations[#destinations + 1] = alias
        end
        for _, namespace in ipairs({ ".titan", ".titan-links", ".native" }) do
            local directory = output .. "/" .. namespace
            if not lfs.attributes(directory) then assert(lfs.mkdir(directory)) end
            local destination = directory .. "/reserved-image.exe"
            write(destination, "retained metadata")
            destinations[#destinations + 1] = destination
        end
        -- A missed preflight would regenerate these objects before failing
        -- publication, even if the OS refuses replacement of an open lock.
        write(source .. "/app.titan", "function main(args: {string}): integer return 1 end\n")
        for _, destination in ipairs(destinations) do
            local bytes = read(destination)
            for _, print_ast in ipairs({ false, true }) do
                local rejected = compile({ "--exe", destination }, print_ast)
                assert.is_false(rejected.ok, destination .. ": " .. tostring(rejected.output))
                assert.matches("input", rejected.output or rejected.diagnostic, 1, true)
                assert.equal(bytes, read(destination))
                assert.equal(lock_bytes, read(lock))
                assert.equal(c_bytes, read(output .. "/app.c"))
                assert.equal(object_bytes, read(output .. "/app.o"))
                local current = assert(lfs.attributes(lock))
                assert.equal(lock_info.dev, current.dev)
                assert.equal(lock_info.ino, current.ino)
            end
        end
        local executable = root .. "/ast-image.exe"
        local ast = compile({ "--exe", executable }, true)
        assert.is_true(ast.ok, ast.output or ast.diagnostic)
        assert.matches("main", ast.output, 1, true)
        local ran = compiler_io.new_sync():run({ executable })
        assert.equal(1, ran.status, ran.output or ran.diagnostic)
        c_bytes, object_bytes = read(output .. "/app.c"), read(output .. "/app.o")
        local executable_bytes = read(executable)
        write(source .. "/app.titan", 'function main(args: {string}): integer return "wrong" end\n')
        local ill_typed = compile({ "--exe", executable }, true)
        assert.is_false(ill_typed.ok, ill_typed.output or ill_typed.diagnostic)
        assert.matches("string", ill_typed.output or ill_typed.diagnostic, 1, true)
        assert.equal(c_bytes, read(output .. "/app.c"))
        assert.equal(object_bytes, read(output .. "/app.o"))
        assert.equal(executable_bytes, read(executable))
    end)

    it("keeps a killed final-link coordinator from overwriting an external successor", function()
        if platform.windows then pending("POSIX final-link process lifetime"); return end
        -- Output routing resolves physical ancestors. Match the wrapper's
        -- input paths against the same spelling (not Darwin's /tmp alias).
        root = assert(compiler_io.new_sync():realpath(root))
        local first, second, delivery = root .. "/first", root .. "/second", root .. "/delivery"
        assert(lfs.mkdir(first)); assert(lfs.mkdir(second)); assert(lfs.mkdir(delivery))
        write(first .. "/app.titan", "function main(args: {string}): integer return 11 end\n")
        write(second .. "/app.titan", "function main(args: {string}): integer return 22 end\n")
        local first_output, second_output = root .. "/objects-one", root .. "/objects-two"
        local executable, release = delivery .. "/shared-image", root .. "/release-native"
        local stage_log, wrapper = root .. "/native-stage", root .. "/link-cc"
        local cdriver = require "c-parser.cdriver"
        local function quote(value) return assert(cdriver.shell_quote(value)) end
        local real = {}
        for _, word in ipairs(assert(cdriver.split_shell_words(require("titan-compiler.driver").CC))) do
            real[#real + 1] = quote(word)
        end
        real = table.concat(real, " ")
        write(wrapper, string.format([[#!/bin/sh
phase=link
output=
next=no
first=no
for argument in "$@"; do
    case "$argument" in -c|-E|-fsyntax-only) phase=compile ;; esac
    case "$argument" in %s*) first=yes ;; esac
    if [ "$next" = yes ]; then output=$argument; next=no
    elif [ "$argument" = -o ]; then next=yes; fi
done
if [ "$phase" = link ] && [ "${output##*/}" = shared-image ] && [ "$first" = yes ]; then
    printf '%%s' "$output" > %s
    printf 'acquired\n'
    attempts=0
    while [ ! -e %s ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 400 ] || exit 97
        sleep 0.05
    done
    %s "$@"
    status=$?
    printf 'native-done\n'
    exit "$status"
fi
exec %s "$@"
]], quote(first_output .. "/"), quote(stage_log), quote(release), real, real))
        assert(compiler_io.new_sync():run({ "chmod", "u+x", wrapper }).ok)
        write(frontend, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/titan-runtime/bootstrap/?.so;" .. package.cpath
local hold = arg[1] == "hold"
local build = require "titan-compiler.build"
if not hold then
    local run = build.run
    build.run = function(...)
        io.stdout:write("acquired\n"); io.stdout:flush()
        return run(...)
    end
end
arg = { [0] = %q .. "/titanc", "-v", "--incremental",
    "--tree", hold and %q or %q, "--output", hold and %q or %q,
    "--exe", %q, "app" }
dofile(%q .. "/titanc")
]], repository, repository, repository, first, second, first_output, second_output, executable, repository))
        local unprotected
        local successor_image, successor_companions
        local function companion_snapshot()
            local result = {}
            local function visit(path, relative)
                local kind = lfs.symlinkattributes(path, "mode")
                if kind == "directory" then
                    result[relative] = { kind = kind }
                    for name in lfs.dir(path) do
                        if name ~= "." and name ~= ".." then visit(path .. "/" .. name, relative .. "/" .. name) end
                    end
                elseif kind then result[relative] = { kind = kind, bytes = read(path) } end
            end
            visit(executable .. ".dSYM", "")
            return result
        end
        local function release_native() write(release, "release") end
        contend(lua, frontend, {}, {}, true, {
            timeout = 60000, defer_waiter = true, env = compiler_environment({ CC = wrapper }),
            after_holder_exit = function()
                -- No successor exists yet. A retained lock means the native
                -- child must finish first; otherwise delay that child until
                -- after successor publication to expose any late overwrite.
                local lock = assert(require("titan")._output_lock_open(delivery .. "/.titan-build.lock"))
                local held, err = lock:try()
                lock:close()
                assert.is_not_nil(held, err)
                unprotected = held
            end,
            release_orphan = release_native,
            allow_early_waiter = function() return unprotected end,
            after_waiter_exit = function()
                local captured, capture_error = pcall(function()
                    successor_image = read(executable)
                    successor_companions = companion_snapshot()
                end)
                release_native()
                assert.is_true(captured, tostring(capture_error))
            end,
        })
        assert.equal("file", lfs.attributes(executable, "mode"))
        assert.equal(successor_image, read(executable))
        assert.same(successor_companions, companion_snapshot())
        local result = compiler_io.new_sync():run({ executable })
        assert.equal(22, result.status, result.output or result.diagnostic)
        assert.not_equal(executable, read(stage_log))
    end)

    it("rejects a substituted lock leaf rather than proceeding unlocked", function()
        local output = root .. "/build"
        assert(lfs.mkdir(output))
        assert(lfs.mkdir(output .. "/.titan-build.lock"))
        local locks, err = require("titan-compiler.build").lock_outputs(
            compiler_io.new_sync(), { output }, {})
        assert.is_nil(locks)
        assert.matches("cannot lock output directory", err, 1, true)
    end)
end)

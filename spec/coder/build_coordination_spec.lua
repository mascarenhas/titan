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
        local deadline = uv.new_timer()
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
        deadline:start(options.timeout or 15000, 0, function()
            failures[#failures + 1] = "output lock subprocess deadline"
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
        uv.run("nowait")
        assert.same({}, failures, table.concat(events, "\n"))
        assert.is_true(holder_released, table.concat(events, "\n"))
        assert.equal(2, #children, table.concat(events, "\n"))
        assert.equal(0, children[2].code, table.concat(events, "\n"))
        if not terminate then assert.equal(0, children[1].code, table.concat(events, "\n")) end
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

    it("keeps a killed final-link coordinator from overwriting an external successor", function()
        if platform.windows then pending("POSIX final-link process lifetime"); return end
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
            after_waiter_exit = release_native,
        })
        assert.equal("file", lfs.attributes(executable, "mode"))
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

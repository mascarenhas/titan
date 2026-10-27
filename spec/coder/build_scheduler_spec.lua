-- Compiler-owned module builds (titan-compiler.build): lexical import
-- discovery checked against the full parser, the coordinator's dependency
-- order, deterministic output, failure and cancellation, one job-slot ledger
-- shared by worker frontends and their native jobs (with exact parent-Make
-- tokens), and the output-tree lock held by orphaned workers. Workers here
-- are real processes started through the production transport; their entry
-- module is a small protocol client written by the spec.
local assert = require "luassert"
local build = require "titan-compiler.build"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"

local ROOT = lfs.currentdir()
local TIMEOUT = ROOT .. "/spec/support/run_with_timeout.sh"

local function quote(text) return assert(cdriver.shell_quote(text)) end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("a"))
    assert(file:close())
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function lines(path)
    local result = {}
    if not exists(path) then return result end
    for line in read_file(path):gmatch("[^\n]+") do result[#result + 1] = line end
    return result
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function new_workspace()
    local workspace = assert(compiler_io.new_sync():tmpname())
    os.remove(workspace)
    assert(lfs.mkdir(workspace))
    return workspace
end

local function parsed_imports(path, text)
    local nodes, err = parser.parse(path, text)
    if not nodes then return nil, err end
    local imports = {}
    for _, node in ipairs(nodes) do
        if node._tag == "Ast.TopLevelImport" then
            imports[#imports + 1] = { name = node.modname, source_required = node.source_required }
        end
    end
    return imports
end

local function titan_sources(directory, files)
    for entry in lfs.dir(directory) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local path = directory .. "/" .. entry
            local mode = lfs.symlinkattributes(path, "mode")
            if mode == "directory" then
                titan_sources(path, files)
            elseif mode == "file" and entry:match("%.titan$") then
                files[#files + 1] = path
            end
        end
    end
    return files
end

describe("lexical import discovery", function()
    it("matches the parser's imports on every repository Titan source", function()
        local files = {}
        for _, directory in ipairs({ "titan", "spec", "doc" }) do
            if exists(ROOT .. "/" .. directory) then titan_sources(ROOT .. "/" .. directory, files) end
        end
        table.sort(files)
        local compared, with_imports = 0, 0
        for _, path in ipairs(files) do
            local text = read_file(path)
            local expected = parsed_imports(path, text)
            if expected then
                local scanned, scan_err = parser.scan_imports(text)
                assert.is_table(scanned, path .. ": " .. tostring(scan_err))
                assert.same(expected, scanned, path)
                compared = compared + 1
                if #expected > 0 then with_imports = with_imports + 1 end
            end
        end
        assert.truthy(compared > 100, "compared " .. compared .. " sources")
        assert.truthy(with_imports > 50, with_imports .. " sources import modules")
    end)

    local cases = {
        { "plain and parenthesized names",
            'local a = import "a"\nlocal b = import("b.c")\n',
            { { name = "a", source_required = false }, { name = "b.c", source_required = false } } },
        { "declarations in comments are ignored",
            '-- local x = import "no"\n--[==[\nlocal y = import "no"\n]==]\nlocal z = import "z"\n',
            { { name = "z", source_required = false } } },
        { "declarations in strings are ignored",
            'local s = "local x = import \\"no\\""\nlocal t = [[\nlocal y = import "no"\n]]\n' ..
            'local z = import [=[z]=]\n',
            { { name = "z", source_required = false } } },
        { "escapes decode exactly as the parser decodes them",
            'local e = import "a\\x2eb\\u{2E}c"\n',
            { { name = "a.b.c", source_required = false } } },
        { "a .titan suffix requires source",
            'local s = import "pkg.mod.titan"\n',
            { { name = "pkg.mod", source_required = true } } },
        { "standard shorthands normalize",
            'local text = import "string"\nlocal f = import "fs.titan"\n',
            { { name = "titan.string", source_required = false },
              { name = "titan.fs", source_required = true } } },
        { "comments may separate every token",
            'local --[[a]] m --b\n= --c\nimport --d\n( --e\n"m" --f\n) --g\n',
            { { name = "m", source_required = false } } },
        { "foreign imports are not module imports",
            'foreign import "math.h"\nforeign import ("stdio.h")\n', {} },
        { "imports may follow other declarations",
            'local importer = 1\nfunction first(): integer\n  return importer\nend\n' ..
            'local late = import "late"\n',
            { { name = "late", source_required = false } } },
    }
    for _, case in ipairs(cases) do
        it(case[1], function()
            assert.same(case[3], parsed_imports("case.titan", case[2]))
            assert.same(case[3], parser.scan_imports(case[2]))
        end)
    end

    it("defers lexical errors to the parser", function()
        for _, text in ipairs({
            'local a = import "unterminated\n',
            'local a = import "a"\nlocal n = 1x\n',
            'local a = import "a"\n--[[ unclosed\n',
        }) do
            assert.is_nil(parser.scan_imports(text), text)
            assert.is_nil(parsed_imports("case.titan", text), text)
        end
    end)
end)

describe("planned import lists", function()
    local workspace
    before_each(function() workspace = new_workspace() end)
    after_each(function() remove_tree(workspace) end)

    it("use a certified record's saved imports without reading sources", function()
        local strategy = setmetatable({
            read_file = function() error("certified imports must not read sources") end,
        }, { __index = compiler_io.new_sync() })
        local imports = assert(build.imports_for(strategy,
            { kind = "flat", main = workspace .. "/missing.titan",
              files = { workspace .. "/missing.titan" } },
            { status = "miss", reason = "configuration",
              imports = {
                  { name = "b", source_required = false, view = "public", interface = "x" },
                  { name = "c", source_required = true, view = "source", interface = "y" },
              } }))
        assert.same({ { name = "b", source_required = false },
            { name = "c", source_required = true } }, imports)
    end)

    it("scan every folder constituent in canonical order and merge them", function()
        local folder = workspace .. "/app"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/app.titan", 'local x = import "x"\nlocal y = import "y"\n')
        write_file(folder .. "/b.titan", 'local y = import "y.titan"\nlocal z = import "z"\n')
        local imports = assert(build.imports_for(compiler_io.new_sync(), {
            kind = "folder", main = folder .. "/app.titan",
            files = { folder .. "/app.titan", folder .. "/b.titan" },
        }))
        assert.same({
            { name = "x", source_required = false },
            { name = "y", source_required = true },
            { name = "z", source_required = false },
        }, imports)
    end)

    it("keep lexically valid imports before a grammar error and leave lexical errors to the worker", function()
        write_file(workspace .. "/grammar.titan", 'local x = import "x"\nfunction (\n')
        assert.same({ { name = "x", source_required = false } },
            build.imports_for(compiler_io.new_sync(), {
                kind = "flat", main = workspace .. "/grammar.titan",
                files = { workspace .. "/grammar.titan" },
            }))
        write_file(workspace .. "/lexical.titan", 'local x = import "x"\nlocal n = 1x\n')
        assert.same({}, build.imports_for(compiler_io.new_sync(), {
            kind = "flat", main = workspace .. "/lexical.titan",
            files = { workspace .. "/lexical.titan" },
        }))
    end)

    it("report an unreadable constituent", function()
        local imports, err = build.imports_for(compiler_io.new_sync(), {
            kind = "flat", main = workspace .. "/absent.titan",
            files = { workspace .. "/absent.titan" },
        })
        assert.is_nil(imports)
        assert.truthy(err:find("cannot read source", 1, true), err)
    end)
end)

describe("process transport", function()
    it("retains one anchored luv loop across package.loaded resets and GC", function()
        local process = require "titan-compiler.process"
        local first = process.library()
        assert.is_userdata(first._loop)
        package.loaded.luv = nil
        package.loaded["titan-compiler.process"] = nil
        collectgarbage("collect")
        collectgarbage("collect")
        local second = require("titan-compiler.process").library()
        assert.equal(first, second)
        assert.equal(first, package.loaded.luv)
        assert.is_userdata(second._loop)

        -- Also verify in a fresh Lua VM where platform.getenv (under
        -- platform.windows = true) is the very first luv load before
        -- package.loaded is reset and GC runs prior to process.run/uv.spawn.
        local interpreter = assert(second.exepath())
        local ok, term, code = require("titan-compiler.process").run({
            interpreter, "-E", "-e",
            string.format("package.path = %q; package.cpath = %q; local interpreter = %q; ",
                package.path, package.cpath, interpreter) .. [[
assert(package.loaded.luv == nil)
local platform = require "titan-compiler.platform"
local saved_windows = platform.windows
platform.windows = true
platform.getenv("PATH")
platform.windows = saved_windows
local first_uv = assert(package.loaded.luv)
assert(type(first_uv._loop) == "userdata")
package.loaded.luv = nil
package.loaded["titan-compiler.process"] = nil
collectgarbage("collect")
collectgarbage("collect")
local process = require "titan-compiler.process"
local second_uv = process.library()
assert(second_uv == first_uv)
assert(type(second_uv._loop) == "userdata")
package.loaded.luv = nil
package.loaded["titan-compiler.process"] = nil
collectgarbage("collect")
collectgarbage("collect")
local ok, term, code = require("titan-compiler.process").run({ interpreter, "-E", "-e", "os.exit(0)" })
assert(ok == true and term == "exit" and code == 0)
]],
        })
        assert.is_true(ok)
        assert.equal("exit", term)
        assert.equal(0, code)
    end)

    it("runs worker-local argv commands through luv spawn", function()
        local process = require "titan-compiler.process"
        local interpreter = assert(process.library().exepath())
        local ok, term, code = process.run({ interpreter, "-E", "-e", "os.exit(0)" })
        assert.is_true(ok)
        assert.equal("exit", term)
        assert.equal(0, code)
        local bad_ok, bad_term, bad_code = process.run({ interpreter, "-E", "-e", "os.exit(7)" })
        assert.is_nil(bad_ok)
        assert.equal("exit", bad_term)
        assert.equal(7, bad_code)
    end)

    it("round-trips a build worker's native batch, terminal result, and coordinator EOF across platforms", function()
        local workspace = new_workspace()
        local saved_path = package.path
        local ok, failure = xpcall(function()
            local process = require "titan-compiler.process"
            local interpreter = assert(process.library().exepath())
            write_file(workspace .. "/cross_platform_worker.lua", [=[
local build_worker = require "titan-compiler.build_worker"
local process = require "titan-compiler.process"

local worker = {}

function worker.main()
    local session = assert(build_worker.connect())
    local request = session.request
    local captured = process.capture({ request.interpreter, "-E", "-e", "io.stdout:write('pre-ok')" })
    assert(captured.ok and captured.output == "pre-ok", tostring(captured.diagnostic))
    local results, failure, cancelled = session:run_batch(request.batch)
    assert(not failure and not cancelled, tostring(failure or cancelled))
    assert(type(results) == "table" and results[1] and results[1].ok == true)
    assert(session:finish({
        ok = true,
        result = {
            module = request.module,
            captured = captured.output,
            batch_code = results[1].code,
        },
    }))
    os.exit(0)
end

return worker
]=])
            package.path = workspace .. "/?.lua;" .. package.path
            local completed = {}
            local out_log = workspace .. "/batch.out"
            local err_log = workspace .. "/batch.err"
            local scheduler = build.new_scheduler({ { name = "m", deps = {} } }, {
                decide = function() return "build" end,
                request = function(node)
                    return {
                        module = node.name,
                        interpreter = interpreter,
                        batch = {
                            {
                                argv = { interpreter, "-E", "-e", "io.stdout:write('native-batch-ran\\n')" },
                                stdout = out_log,
                                stderr = err_log,
                            },
                        },
                    }
                end,
                complete = function(node, result)
                    completed[node.name] = result
                    return true
                end,
            }, {
                jobs = 2,
                worker_entry = "cross_platform_worker",
                makeflags = false,
            })
            local built, diagnostics = scheduler:run()
            assert.is_true(built, diagnostics and table.concat(diagnostics, "\n"))
            assert.same({
                module = "m",
                captured = "pre-ok",
                batch_code = 0,
            }, completed.m)
            assert.equal("native-batch-ran\n", (read_file(out_log):gsub("\r\n", "\n")))

            local eof_code, eof_settled
            local eof_worker
            eof_worker = assert(process.start_worker({
                interpreter, "-E", "-e",
                string.format("package.path = %q; package.cpath = %q; ", package.path, package.cpath) .. [[
local session = assert(require("titan-compiler.build_worker").connect())
session:run_batch({ { argv = { "unused" }, stdout = "out", stderr = "err" } })
os.exit(0)
]],
            }, {}, {
                record = function(payload)
                    local record = assert(process.decode_record(payload))
                    assert.equal("native", record.kind)
                    eof_worker.request_pipe:close()
                end,
                failed = function() end,
                exited = function(code) eof_code = code end,
                settled = function() eof_settled = true end,
            }))
            assert(eof_worker:send(assert(process.encode_record({
                kind = "compile",
                protocol = require("titan-compiler.version").BUILD_WORKER_PROTOCOL,
                request = { module = "eof" },
            }))))
            while not eof_settled do process.library().run("once") end
            assert.equal(3, eof_code)

            -- Also verify Session:abandoned() (Control:poll() with
            -- control.reader as the sole handle) observes coordinator EOF.
            local uv = process.library()
            local ready_marker = workspace .. "/abandoned.ready"
            local abandoned_code, abandoned_settled
            local abandoned_worker, ready_timer, deadline_timer
            local function cleanup_abandoned()
                if ready_timer and not ready_timer:is_closing() then ready_timer:close() end
                if deadline_timer and not deadline_timer:is_closing() then deadline_timer:close() end
                if abandoned_worker and not abandoned_worker.exited then
                    abandoned_worker:kill("sigkill")
                end
                while abandoned_worker and not abandoned_settled do uv.run("once") end
                uv.run("nowait")
            end
            local ran_abandoned, abandoned_err = xpcall(function()
                abandoned_worker = assert(process.start_worker({
                    interpreter, "-E", "-e",
                    string.format("package.path = %q; package.cpath = %q; ", package.path, package.cpath) ..
                    string.format([[
local process = require "titan-compiler.process"
local session = assert(require("titan-compiler.build_worker").connect())
local file = assert(io.open(%q, "wb"))
assert(file:write("ready\n"))
assert(file:close())
for _ = 1, 1000 do
    if session:abandoned() then os.exit(3) end
    process.library().sleep(10)
end
os.exit(0)
]], ready_marker),
                }, {}, {
                    record = function() end,
                    failed = function() end,
                    exited = function(code) abandoned_code = code end,
                    settled = function() abandoned_settled = true end,
                }))
                assert(abandoned_worker:send(assert(process.encode_record({
                    kind = "compile",
                    protocol = require("titan-compiler.version").BUILD_WORKER_PROTOCOL,
                    request = { module = "abandoned" },
                }))))
                uv.update_time()
                ready_timer = uv.new_timer()
                ready_timer:start(5, 5, function()
                    if exists(ready_marker) then
                        ready_timer:stop()
                        ready_timer:close()
                        if not abandoned_worker.request_pipe:is_closing() then
                            abandoned_worker.request_pipe:close()
                        end
                    end
                end)
                deadline_timer = uv.new_timer()
                deadline_timer:start(15000, 0, function()
                    if not abandoned_worker.exited then abandoned_worker:kill("sigkill") end
                end)
                deadline_timer:unref()
                while not abandoned_settled do uv.run("once") end
            end, debug.traceback)
            cleanup_abandoned()
            assert.is_true(ran_abandoned, abandoned_err)
            assert.equal(3, abandoned_code)
        end, debug.traceback)
        package.path = saved_path
        remove_tree(workspace)
        assert.is_true(ok, failure)
    end)
end)

describe("native precise stat", function()
    local workspace
    before_each(function() workspace = new_workspace() end)
    after_each(function() remove_tree(workspace) end)

    it("reports integer nanosecond ctime changes after a restored-mtime rewrite and shares hardlink identity", function()
        local support = require "titan"
        if type(support._stat_precise) ~= "function" then
            pending("native _stat_precise requires a reinstalled runtime")
            return
        end
        local absent, absent_err, absent_code =
            support._stat_precise(workspace .. "/missing", true)
        assert.is_nil(absent)
        assert.truthy(tostring(absent_err):find("ENOENT", 1, true), absent_err)
        assert.equal(2, absent_code)

        local reference = workspace .. "/reference.txt"
        local target = workspace .. "/target.txt"
        local hard = workspace .. "/hard.txt"
        write_file(reference, "aaaa")
        write_file(target, "aaaa")
        assert(lfs.link(target, hard))
        if not platform.windows then
            assert(os.execute("touch -r " .. quote(reference) .. " " .. quote(target)))
        end
        local before = assert(support._stat_precise(target, true))
        local hard_obs = assert(support._stat_precise(hard, true))
        local dir_obs = assert(support._stat_precise(workspace, true))
        assert.equal("directory", dir_obs.kind)
        assert.equal("file", before.kind)
        assert.equal(4, before.size)
        assert.equal("integer", math.type(before.size))
        assert.equal("integer", math.type(before.mode))
        assert.equal("integer", math.type(before.mtime_ns))
        assert.equal("integer", math.type(before.ctime_ns))
        assert.is_string(before.dev)
        assert.is_string(before.ino)
        assert.equal(before.dev, hard_obs.dev)
        assert.equal(before.ino, hard_obs.ino)

        require("titan-compiler.process").library().sleep(20)
        write_file(target, "bbbb")
        if platform.windows then
            local uv = require("titan-compiler.process").library()
            local sec = before.mtime_ns / 1000000000
            assert(uv.fs_utime(target, sec, sec))
        else
            assert(os.execute("touch -r " .. quote(reference) .. " " .. quote(target)))
        end
        local after = assert(support._stat_precise(target, true))
        assert.equal(before.size, after.size)
        assert.equal(before.dev, after.dev)
        assert.equal(before.ino, after.ino)
        if not platform.windows then
            assert.equal(before.mtime_ns, after.mtime_ns)
        end
        assert.is_true(after.ctime_ns > before.ctime_ns,
            tostring(before.ctime_ns) .. " -> " .. tostring(after.ctime_ns))
    end)
end)

-- The worker side of the protocol, driven by the request the test's hooks
-- send: frontend accounting through a shared counter, native batches through
-- the coordinator, output, results, malformed records and orphan behavior.
local FAKE_WORKER = [=[
local build_worker = require "titan-compiler.build_worker"
local process = require "titan-compiler.process"

local fake = {}

local function quote(word) return "'" .. tostring(word):gsub("'", "'\\''") .. "'" end

local function append(path, line)
    local file = assert(io.open(path, "ab"))
    assert(file:write(line, "\n"))
    assert(file:close())
end

local function counter(request, action)
    if request.counter then
        assert(os.execute("sh " .. quote(request.counter) .. " " ..
            quote(request.state) .. " " .. action))
    end
end

function fake.main()
    local session = assert(build_worker.connect())
    local request = session.request
    if request.log then append(request.log, "start " .. request.module) end
    if request.garbage then
        session.control.pipe:write("\255\255\255\255garbage", function()
            os.exit(0)
        end)
        process.library().run()
    end
    counter(request, "enter")
    local ok = request.ok ~= false
    for _, batch in ipairs(request.batches or {}) do
        counter(request, "leave")
        local results, failure, cancelled = session:run_batch(batch)
        counter(request, "enter")
        local outcomes = {}
        for index = 1, #batch do
            local result = results and results[index]
            outcomes[index] = result and tostring(result.ok) or "unstarted"
        end
        if request.log then
            append(request.log, "batch " .. request.module .. " " ..
                table.concat(outcomes, ",") .. " " .. tostring(failure) .. " " ..
                tostring(cancelled))
        end
        if failure or cancelled then ok = false end
    end
    if request.stdout then io.stdout:write(request.stdout) end
    if request.stderr then io.stderr:write(request.stderr) end
    if request.frontend_sleep then process.library().sleep(request.frontend_sleep) end
    if request.orphan_sleep then
        process.library().sleep(request.orphan_sleep)
        append(request.orphan_marker, "orphan done")
    end
    counter(request, "leave")
    if request.log then append(request.log, "finish " .. request.module) end
    if request.exit then
        io.stdout:flush()
        os.exit(request.exit)
    end
    session:finish({ ok = ok, result = { module = request.module, staged = request.staged },
        diagnostics = request.diagnostics })
    os.exit(0)
end

return fake
]=]

-- Counts concurrently active frontends and native jobs in one state
-- directory and records the maximum.
local COUNTER = [=[
#!/bin/sh
state=$1
action=$2
lock() { while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done; }
unlock() { rmdir "$state/lock"; }
enter() {
    lock
    active=0
    test ! -f "$state/active" || active=$(cat "$state/active")
    active=$((active + 1))
    printf '%s\n' "$active" > "$state/active"
    maximum=0
    test ! -f "$state/maximum" || maximum=$(cat "$state/maximum")
    if [ "$active" -gt "$maximum" ]; then printf '%s\n' "$active" > "$state/maximum"; fi
    unlock
}
leave() {
    lock
    active=$(cat "$state/active")
    printf '%s\n' $((active - 1)) > "$state/active"
    unlock
}
case "$action" in
    enter) enter ;;
    leave) leave ;;
    job) enter; printf '%s\n' "$4" >> "$state/jobs"; sleep "$3"; leave ;;
esac
]=]

describe("module build scheduler", function()
    if platform.windows then
        it("is exercised through POSIX shell fixtures", function()
            pending("the scheduler fixtures use sh; Windows runs the titanc lanes")
        end)
        return
    end

    local workspace, state, log, saved_path, saved_stderr, captured

    before_each(function()
        workspace = new_workspace()
        state = workspace .. "/state"
        assert(lfs.mkdir(state))
        log = workspace .. "/log"
        write_file(workspace .. "/fake_build_worker.lua", FAKE_WORKER)
        write_file(workspace .. "/counter.sh", COUNTER)
        saved_path = package.path
        package.path = workspace .. "/?.lua;" .. package.path
        saved_stderr = io.stderr
        captured = {}
        io.stderr = {
            write = function(_, ...)
                for index = 1, select("#", ...) do
                    captured[#captured + 1] = tostring(select(index, ...))
                end
                return true
            end,
            flush = function() return true end,
        }
    end)

    after_each(function()
        io.stderr = saved_stderr
        package.path = saved_path
        remove_tree(workspace)
    end)

    local function maximum()
        return tonumber(read_file(state .. "/maximum"))
    end

    local function active()
        return exists(state .. "/active") and tonumber(read_file(state .. "/active")) or 0
    end

    local function job(name, delay)
        return {
            argv = { "sh", workspace .. "/counter.sh", state, "job", tostring(delay or 0.2), name },
            stdout = workspace .. "/" .. name .. ".out",
            stderr = workspace .. "/" .. name .. ".err",
        }
    end

    -- Nodes from { name, { dependency names } } in plan order.
    local function graph(spec)
        local nodes, by_name = {}, {}
        for _, entry in ipairs(spec) do
            local node = { name = entry[1], deps = {} }
            nodes[#nodes + 1] = node
            by_name[entry[1]] = node
        end
        for index, entry in ipairs(spec) do
            for _, dependency in ipairs(entry[2] or {}) do
                nodes[index].deps[#nodes[index].deps + 1] = assert(by_name[dependency])
            end
        end
        return nodes
    end

    -- Hooks over a per-module request table; records completions/discards.
    local function hooks(requests, record)
        record.completed, record.discarded, record.requested = {}, {}, {}
        return {
            decide = function(node)
                local decision = requests[node.name] and requests[node.name].decision
                return decision or "build"
            end,
            request = function(node, jobs_bound)
                record.requested[#record.requested + 1] = node.name
                record.jobs_bound = jobs_bound
                local request = { module = node.name, log = log }
                for key, value in pairs(requests[node.name] or {}) do
                    if key ~= "decision" then request[key] = value end
                end
                return request
            end,
            complete = function(node, result)
                assert.equal(node.name, result.module)
                record.completed[#record.completed + 1] = node.name
                return true
            end,
            discard = function(node)
                record.discarded[#record.discarded + 1] = node.name
            end,
        }
    end

    local function run(nodes, requests, options)
        local record = {}
        options = options or {}
        options.worker_entry = "fake_build_worker"
        if options.makeflags == nil then options.makeflags = false end
        local scheduler = build.new_scheduler(nodes, hooks(requests, record), options)
        local ok, diagnostics, signo = scheduler:run()
        record.scheduler = scheduler
        return ok, diagnostics, signo, record
    end

    it("starts no worker when every module is certified", function()
        local ok, diagnostics, _, record = run(graph({ { "a" }, { "b", { "a" } } }), {
            a = { decision = "done" }, b = { decision = "done" },
        }, { jobs = 4 })
        assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
        assert.equal(0, record.scheduler.started)
        assert.same({}, record.requested)
        assert.falsy(exists(log))
    end)

    it("builds a diamond in dependency order and emits output in plan order", function()
        local nodes = graph({ { "a" }, { "b", { "a" } }, { "c", { "a" } }, { "d", { "b", "c" } } })
        local ok, diagnostics, _, record = run(nodes, {
            a = { stdout = "out a\n" },
            b = { stdout = "out b\n", batches = { { job("b-slow", 0.6) } } },
            c = { stdout = "out c\n", stderr = "" },
            d = { stdout = "out d\n" },
        }, { jobs = 4 })
        assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
        local events = lines(log)
        local position = {}
        for index, event in ipairs(events) do position[event] = index end
        assert.truthy(position["finish a"] < position["start b"], table.concat(events, "\n"))
        assert.truthy(position["finish a"] < position["start c"], table.concat(events, "\n"))
        assert.truthy(position["finish b"] < position["start d"], table.concat(events, "\n"))
        assert.truthy(position["finish c"] < position["start d"], table.concat(events, "\n"))
        -- c finished long before b, yet output follows the plan.
        assert.same({ "a", "c", "b", "d" }, record.completed)
        assert.equal("out a\nout b\nout c\nout d\n", table.concat(captured))
    end)

    it("fails one module, skips its dependents, and finishes independent work", function()
        local nodes = graph({ { "a" }, { "b" }, { "c", { "b" } }, { "d", { "a" } } })
        local ok, diagnostics, signo, record = run(nodes, {
            b = { ok = false, diagnostics = { "b.titan:1:1: type error: broken" } },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.is_nil(signo)
        assert.same({ "b.titan:1:1: type error: broken" }, diagnostics)
        assert.same({ "a", "d" }, record.completed)
        table.sort(record.requested)
        assert.same({ "a", "b", "d" }, record.requested)
    end)

    it("rejects malformed control records and missing results", function()
        local ok, diagnostics = run(graph({ { "garbled" }, { "silent" } }), {
            garbled = { garbage = true }, silent = { exit = 3 },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.equal(2, #diagnostics)
        assert.truthy(diagnostics[1]:find("build worker for module 'garbled' failed:", 1, true),
            diagnostics[1])
        assert.truthy(diagnostics[1]:find("exceeds its bound", 1, true), diagnostics[1])
        assert.equal("build worker for module 'silent' exited with status 3 " ..
            "without reporting a result", diagnostics[2])
    end)

    local function busy_requests(names, jobs_per_module)
        local requests = {}
        for _, name in ipairs(names) do
            local batch = {}
            for index = 1, jobs_per_module do batch[index] = job(name .. index, 0.3) end
            requests[name] = {
                counter = workspace .. "/counter.sh", state = state,
                batches = { batch },
            }
        end
        return requests
    end

    it("bounds running frontends and native jobs together by the local cap", function()
        local names = { "m1", "m2", "m3", "m4" }
        local ok, diagnostics, _, record = run(graph({ { "m1" }, { "m2" }, { "m3" }, { "m4" } }),
            busy_requests(names, 3), { jobs = 2 })
        assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
        assert.equal(2, record.jobs_bound)
        assert.equal(12, #lines(state .. "/jobs"))
        assert.equal(2, maximum())
        assert.equal(0, active())
        assert.equal(4, #record.completed)
    end)

    describe("under a parent Make FIFO pool", function()
        local fifo, holder
        local support = require "titan"

        before_each(function()
            fifo = workspace .. "/pool"
            assert(os.execute("mkfifo -m 600 " .. quote(fifo)))
            holder = assert(io.open(fifo, "r+"))
            assert(holder:setvbuf("no"))
            assert(holder:write("\0\255"))
        end)

        after_each(function()
            if holder then holder:close() end
            holder = nil
        end)

        local function available()
            local probe = assert(support._jobserver_open("fifo", fifo))
            local count = 0
            while assert(probe:acquire() ~= nil) and probe:held() > count do
                count = count + 1
            end
            assert(probe:close())
            return count
        end

        it("holds exact tokens beyond its implicit slot and returns them", function()
            local names = { "m1", "m2", "m3", "m4" }
            local ok, diagnostics = run(graph({ { "m1" }, { "m2" }, { "m3" }, { "m4" } }),
                busy_requests(names, 2), {
                    jobs = 8, makeflags = "-j3 --jobserver-auth=fifo:" .. fifo,
                })
            assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
            assert.equal(8, #lines(state .. "/jobs"))
            -- One implicit slot plus the pool's two tokens.
            assert.equal(3, maximum())
            assert.equal(0, active())
            assert.equal(2, available())
            local bytes = { holder:read(2):byte(1, -1) }
            table.sort(bytes)
            assert.same({ 0, 255 }, bytes)
        end)

        it("drains a cancelled batch and returns every token", function()
            -- The first job signals the coordinator while it runs; the two
            -- tokens already run the next jobs, the fourth job stays queued
            -- and the dependent module never starts.
            local cancel_job = {
                argv = { "sh", "-c", 'kill -TERM "$PPID"; sleep 0.3; echo first >> ' ..
                    quote(state .. "/jobs") },
                stdout = workspace .. "/cancel.out", stderr = workspace .. "/cancel.err",
            }
            local ok, diagnostics, signo, record = run(graph({ { "one" }, { "two", { "one" } } }), {
                one = { batches = { { cancel_job, job("j2", 0.3), job("j3", 0.3), job("j4", 0) } } },
            }, { jobs = 8, makeflags = "-j3 --jobserver-auth=fifo:" .. fifo })
            assert.is_nil(ok)
            assert.equal(15, signo)
            assert.truthy(diagnostics[#diagnostics]:find("interrupted by signal 15", 1, true))
            local ran = lines(state .. "/jobs")
            table.sort(ran)
            assert.same({ "first", "j2", "j3" }, ran)
            assert.same({ "one" }, record.requested)
            assert.same({}, record.completed)
            assert.truthy(table.concat(lines(log), "\n"):find(
                "batch one true,true,true,unstarted nil 15", 1, true),
                table.concat(lines(log), "\n"))
            assert.equal(0, active())
            assert.equal(2, available())
        end)
    end)

    it("drops queued native work after a cancellation", function()
        local cancel_job = {
            argv = { "sh", "-c", 'kill -TERM "$PPID"; sleep 0.3; echo first >> ' ..
                quote(state .. "/jobs") },
            stdout = workspace .. "/cancel.out", stderr = workspace .. "/cancel.err",
        }
        local ok, _, signo, record = run(graph({ { "one" }, { "two" } }), {
            one = { batches = { { cancel_job, job("second", 0) } } },
        }, { jobs = 1 })
        assert.is_nil(ok)
        assert.equal(15, signo)
        assert.same({ "first" }, lines(state .. "/jobs"))
        assert.same({ "one" }, record.requested)
        assert.same({}, record.completed)
        assert.truthy(table.concat(lines(log), "\n"):find(
            "batch one true,unstarted nil 15", 1, true), table.concat(lines(log), "\n"))
    end)

    it("discards a successful result once the build has stopped", function()
        local cancel_job = {
            argv = { "sh", "-c", 'kill -TERM "$PPID"; sleep 0.5' },
            stdout = workspace .. "/cancel.out", stderr = workspace .. "/cancel.err",
        }
        local ok, _, signo, record = run(graph({ { "slow" }, { "quick" } }), {
            slow = { batches = { { cancel_job } } },
            quick = { frontend_sleep = 1000 },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.equal(15, signo)
        assert.same({}, record.completed)
        assert.same({ "quick" }, record.discarded)
    end)

    it("keeps the output tree locked until an orphaned worker exits", function()
        local tree = workspace .. "/tree"
        assert(lfs.mkdir(tree))
        local marker = workspace .. "/marker"
        local interpreter = assert(require("titan-compiler.process").library().exepath())
        local prelude = string.format("package.path = %q\npackage.cpath = %q\n",
            package.path, package.cpath) ..
            'local build = require "titan-compiler.build"\n' ..
            'local strategy = require("titan-compiler.io").new_sync()\n'
        write_file(workspace .. "/coordinator.lua", prelude .. string.format([[
local locks = assert(build.lock_outputs(strategy, { %q }))
local scheduler = build.new_scheduler({ { name = "orphan", deps = {} } }, {
    decide = function() return "build" end,
    request = function(node)
        return { module = node.name, log = %q, orphan_sleep = 1500, orphan_marker = %q }
    end,
    complete = function() return true end,
}, { jobs = 2, locks = locks, worker_entry = "fake_build_worker", makeflags = false })
scheduler:run()
]], tree, log, marker))
        write_file(workspace .. "/successor.lua", prelude .. string.format([[
local locks = assert(build.lock_outputs(strategy, { %q }, { verbose = true }))
local file = assert(io.open(%q, "ab"))
file:write("successor locked\n")
file:close()
locks:release()
]], tree, marker))
        local pid_file = workspace .. "/coordinator.pid"
        assert(os.execute("sh -c " .. quote(quote(interpreter) .. " " ..
            quote(workspace .. "/coordinator.lua") .. " >/dev/null 2>&1 & echo $! > " ..
            quote(pid_file))))
        for _ = 1, 400 do
            if #lines(log) > 0 then break end
            os.execute("sleep 0.05")
        end
        assert.same({ "start orphan" }, lines(log))
        assert(os.execute("kill -KILL " .. assert(tonumber(read_file(pid_file)))))
        local pipe = assert(io.popen(quote(TIMEOUT) .. " 30 " .. quote(interpreter) ..
            " " .. quote(workspace .. "/successor.lua") .. " 2>&1", "r"))
        local output = pipe:read("a")
        local closed = pipe:close()
        assert.truthy(closed, output)
        assert.truthy(output:find("waiting for build lock", 1, true), output)
        assert.same({ "orphan done", "successor locked" }, lines(marker))
    end)

    it("keeps the output tree locked until an orphaned native batch job exits", function()
        local tree = workspace .. "/tree"
        assert(lfs.mkdir(tree))
        local marker = workspace .. "/marker"
        local job_started = workspace .. "/job.started"
        local interpreter = assert(require("titan-compiler.process").library().exepath())
        local prelude = string.format("package.path = %q\npackage.cpath = %q\n",
            package.path, package.cpath) ..
            'local build = require "titan-compiler.build"\n' ..
            'local strategy = require("titan-compiler.io").new_sync()\n'
        write_file(workspace .. "/coordinator.lua", prelude .. string.format([[
local locks = assert(build.lock_outputs(strategy, { %q }))
local scheduler = build.new_scheduler({ { name = "orphan", deps = {} } }, {
    decide = function() return "build" end,
    request = function(node)
        return {
            module = node.name, log = %q,
            batches = { {
                {
                    argv = { "sh", "-c", "echo started > " .. %q .. "; sleep 1.5; echo 'orphan native done' >> " .. %q },
                    stdout = %q, stderr = %q,
                },
            } },
        }
    end,
    complete = function() return true end,
}, { jobs = 2, locks = locks, worker_entry = "fake_build_worker", makeflags = false })
scheduler:run()
]], tree, log, quote(job_started), quote(marker), workspace .. "/native.out", workspace .. "/native.err"))
        write_file(workspace .. "/successor.lua", prelude .. string.format([[
local locks = assert(build.lock_outputs(strategy, { %q }, { verbose = true }))
local file = assert(io.open(%q, "ab"))
file:write("successor locked\n")
file:close()
locks:release()
]], tree, marker))
        local pid_file = workspace .. "/coordinator.pid"
        assert(os.execute("sh -c " .. quote(quote(interpreter) .. " " ..
            quote(workspace .. "/coordinator.lua") .. " >/dev/null 2>&1 & echo $! > " ..
            quote(pid_file))))
        for _ = 1, 400 do
            if exists(job_started) then break end
            os.execute("sleep 0.05")
        end
        assert.truthy(exists(job_started))
        assert(os.execute("kill -KILL " .. assert(tonumber(read_file(pid_file)))))
        local pipe = assert(io.popen(quote(TIMEOUT) .. " 30 " .. quote(interpreter) ..
            " " .. quote(workspace .. "/successor.lua") .. " 2>&1", "r"))
        local output = pipe:read("a")
        local closed = pipe:close()
        assert.truthy(closed, output)
        assert.truthy(output:find("waiting for build lock", 1, true), output)
        assert.same({ "orphan native done", "successor locked" }, lines(marker))
    end)
end)

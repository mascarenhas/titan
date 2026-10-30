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

-- Replace io.stderr until the returned restore function runs; `on_write`
-- observes each write.
local function capture_stderr(on_write)
    local saved, written = io.stderr, {}
    io.stderr = {
        write = function(_, ...)
            for index = 1, select("#", ...) do written[#written + 1] = tostring(select(index, ...)) end
            if on_write then on_write() end
            return true
        end,
        flush = function() return true end,
    }
    return written, function() io.stderr = saved end
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

describe("worker request records", function()
    local graphcodec = require "titan-compiler.graphcodec"
    local process = require "titan-compiler.process"
    local encode = graphcodec.encode
    after_each(function() graphcodec.encode = encode end)

    -- Model the record codec's bounds at a small scale. The real bounds are
    -- 64 MiB per string and 256 MiB per record, plus node and entry counts.
    local function bounded(limits)
        graphcodec.encode = function(record, options)
            local scaled = {}
            for key, value in pairs(options or {}) do scaled[key] = value end
            for key, value in pairs(limits) do scaled[key] = value end
            return encode(record, scaled)
        end
    end
    local function request(archives, module)
        return { module = module or "app", options = { plan = {
            modname = module or "app",
            modules = { app = { kind = "source" }, dep = { kind = "static", archive = "/sdk/dep.a" } },
            archives = archives,
        } } }
    end
    local function metadata(count, size)
        local modules = {}
        for index = 1, count do
            modules["dep" .. index] = { payload = string.rep("p", size), origin = "member " .. index }
        end
        return { ["/sdk/dep.a"] = { observation = { precision = "ns" }, modules = modules } }
    end
    local function sent(payload)
        local record = assert(process.decode_record(payload))
        assert.equal("compile", record.kind)
        assert.equal("app", record.request.options.plan.modname)
        assert.equal("/sdk/dep.a", record.request.options.plan.modules.dep.archive)
        return record.request.options.plan.archives
    end

    it("keeps archive metadata that fits every bound", function()
        bounded({ max_string_bytes = 4096, max_bytes = 65536 })
        local archives = metadata(2, 1024)
        assert.same(archives, sent(assert(build.encode_request(request(archives)))))
    end)

    it("sends the request without archive metadata that exceeds a bound", function()
        for _, case in ipairs({
            { "string", { max_string_bytes = 4096 }, metadata(1, 4097) },
            { "record bytes", { max_bytes = 16384 }, metadata(8, 4000) },
            { "entries", { max_entries = 64 }, metadata(40, 1) },
            { "nodes", { max_nodes = 32 }, metadata(40, 1) },
        }) do
            bounded(case[2])
            local payload, err = build.encode_request(request(case[3]))
            assert.truthy(payload, case[1] .. ": " .. tostring(err))
            assert.is_nil(sent(payload), case[1])
        end
    end)

    it("still reports a request that exceeds a bound without archive metadata", function()
        bounded({ max_string_bytes = 64 })
        local payload, err = build.encode_request(request(metadata(1, 128), string.rep("m", 65)))
        assert.is_nil(payload)
        assert.truthy(err:find("graph string limit exceeded", 1, true), err)
    end)
end)

describe("process transport", function()
    it("retains one anchored luv loop across package.loaded resets and GC", function()
        local weak = setmetatable({}, { __mode = "v" })
        do
            local process = require "titan-compiler.process"
            local first = process.library()
            assert.is_userdata(first._loop)
            weak.uv, weak.loop = first, first._loop
        end
        package.loaded.luv = nil
        package.loaded["titan-compiler.process"] = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert.is_table(weak.uv)
        assert.is_userdata(weak.loop)
        local second = require("titan-compiler.process").library()
        assert.equal(weak.uv, second)
        assert.equal(weak.uv, package.loaded.luv)
        assert.equal(weak.loop, second._loop)

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
local weak = setmetatable({}, { __mode = "v" })
do
    local first_uv = assert(package.loaded.luv)
    assert(type(first_uv._loop) == "userdata")
    weak.uv, weak.loop = first_uv, first_uv._loop
end
package.loaded.luv = nil
package.loaded["titan-compiler.process"] = nil
collectgarbage("collect")
collectgarbage("collect")
assert(weak.uv ~= nil and type(weak.loop) == "userdata")
do
    local process = require "titan-compiler.process"
    local second_uv = process.library()
    assert(second_uv == weak.uv)
    assert(second_uv._loop == weak.loop)
    assert(type(second_uv._loop) == "userdata")
end
package.loaded.luv = nil
package.loaded["titan-compiler.process"] = nil
collectgarbage("collect")
collectgarbage("collect")
assert(weak.uv ~= nil and type(weak.loop) == "userdata")
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

    it("runs captured commands in the C locale with added and removed variables", function()
        local process = require "titan-compiler.process"
        local uv = process.library()
        assert(uv.os_setenv("TITAN_SPEC_INHERITED", "parent"))
        local captured = process.capture({ assert(uv.exepath()), "-E", "-e",
            "io.write(tostring(os.getenv('TITAN_SPEC_INHERITED')), ' ', " ..
            "tostring(os.getenv('TITAN_SPEC_ADDED')), ' ', tostring(os.getenv('LC_ALL')))" },
            { env = { TITAN_SPEC_INHERITED = false, TITAN_SPEC_ADDED = "added" } })
        uv.os_unsetenv("TITAN_SPEC_INHERITED")
        assert.is_true(captured.ok, captured.diagnostic)
        assert.equal("nil added C", captured.output)
    end)

    it("reports a command or worker that cannot start instead of raising", function()
        local process = require "titan-compiler.process"
        local workspace = new_workspace()
        local missing = workspace .. "/missing-tool"
        local written, restore = capture_stderr()
        local ran, ok, term, code = pcall(process.run, { missing, "--version" })
        restore()
        local worker, worker_err = process.start_worker({ missing }, {}, {
            record = function() end, failed = function() end,
            exited = function() end, settled = function() end,
        })
        remove_tree(workspace)
        assert.is_true(ran, ok)
        assert.is_nil(ok)
        assert.equal("exit", term)
        assert.equal(127, code)
        local text = table.concat(written)
        assert.truthy(text:find("titanc: cannot start '" .. missing .. "': ", 1, true), text)
        assert.is_nil(worker)
        assert.is_string(worker_err)
    end)

    it("refuses to send to a worker whose control channel has closed", function()
        local process = require "titan-compiler.process"
        local uv = process.library()
        local events = {}
        local worker = assert(process.start_worker({ assert(uv.exepath()), "-E", "-e", "os.exit(0)" }, {}, {
            record = function() events[#events + 1] = "record" end,
            failed = function(failure) events[#events + 1] = "failed " .. tostring(failure) end,
            exited = function(code) events[#events + 1] = "exited " .. tostring(code) end,
            settled = function() events[#events + 1] = "settled" end,
        }))
        while events[#events] ~= "settled" do uv.run("once") end
        assert.same({ "exited 0", "settled" }, events)
        local sent, err = worker:send(assert(process.encode_record({ kind = "compile" })))
        assert.is_nil(sent)
        assert.equal("the control channel is closed", err)
        -- Signalling a worker that already exited is not an error.
        assert.is_true(worker:kill("sigterm"))
    end)
end)

-- The worker's end of the control channel, driven in this process: two OS
-- pipes stand in for a worker's descriptors 3 and 4, and the spec plays the
-- coordinator by writing framed requests into one and reading the worker's
-- framed replies from the other.
describe("build worker control sessions", function()
    local build_worker = require "titan-compiler.build_worker"
    local process = require "titan-compiler.process"
    local version = require "titan-compiler.version"
    local uv = process.library()
    local coordinator_ends

    local function pipes()
        local requests, replies = assert(uv.pipe()), assert(uv.pipe())
        coordinator_ends[#coordinator_ends + 1] = requests.write
        coordinator_ends[#coordinator_ends + 1] = replies.read
        return requests, replies
    end

    -- The coordinator closes its request end: the worker sees end of file.
    local function close_requests(requests)
        for index, descriptor in ipairs(coordinator_ends) do
            if descriptor == requests.write then
                table.remove(coordinator_ends, index)
                break
            end
        end
        uv.fs_close(requests.write)
    end

    local function write_bytes(requests, bytes)
        assert(uv.fs_write(requests.write, bytes, -1))
    end

    local function send(requests, record)
        write_bytes(requests, process.frame(assert(process.encode_record(record))))
    end

    local function read_exact(replies, count)
        local chunks, size = {}, 0
        while size < count do
            local chunk = assert(uv.fs_read(replies.read, count - size, -1))
            assert(#chunk > 0, "the worker closed its reply channel early")
            chunks[#chunks + 1] = chunk
            size = size + #chunk
        end
        return table.concat(chunks)
    end

    local function receive(replies)
        local length = string.unpack(">I4", read_exact(replies, 4))
        return assert(process.decode_record(read_exact(replies, length)))
    end

    local function compile_request(request)
        return { kind = "compile", protocol = version.BUILD_WORKER_PROTOCOL, request = request }
    end

    before_each(function() coordinator_ends = {} end)
    after_each(function()
        for _, descriptor in ipairs(coordinator_ends) do uv.fs_close(descriptor) end
        uv.run("nowait")
    end)

    it("answers each native batch with the coordinator reply of the same id", function()
        local requests, replies = pipes()
        send(requests, compile_request({ module = "app", options = { jobs = 2 } }))
        local session = assert(build_worker.connect(requests.read, replies.write))
        assert.same({ module = "app", options = { jobs = 2 } }, session.request)

        local batch = { { argv = { "cc", "-c", "app.c" }, stdout = "/logs/app.out", stderr = "/logs/app.err" } }
        -- A reply whose bytes arrive in two writes, the second while the
        -- worker already waits for it, is still one record.
        local answer = process.frame(assert(process.encode_record({
            kind = "native-result", id = 1, results = { { ok = true, term = "exit", code = 0 } },
            cancelled = 15,
        })))
        write_bytes(requests, answer:sub(1, 3))
        local timer = uv.new_timer()
        timer:start(20, 0, function()
            timer:close()
            write_bytes(requests, answer:sub(4))
        end)
        local results, failure, cancelled = session:run_batch(batch)
        assert.same({ { ok = true, term = "exit", code = 0 } }, results)
        assert.is_nil(failure)
        assert.equal(15, cancelled)
        assert.same({ kind = "native", id = 1, jobs = batch }, receive(replies))

        -- A reply to another batch or an undecodable reply is a protocol
        -- failure that run_batch returns rather than raises.
        send(requests, { kind = "native-result", id = 1, results = {} })
        local stale, stale_err = session:run_batch(batch)
        assert.is_nil(stale)
        assert.equal("unexpected build coordinator reply", stale_err)
        assert.equal(2, receive(replies).id)
        write_bytes(requests, process.frame("\0not a control record"))
        local garbled, garbled_err = session:run_batch(batch)
        assert.is_nil(garbled)
        assert.is_string(garbled_err)
        assert.equal(3, receive(replies).id)

        -- A batch the record codec cannot carry never reaches the coordinator.
        local unencodable, encode_err = session:run_batch({ { argv = { function() end } } })
        assert.is_nil(unencodable)
        assert.truthy(encode_err:find("cannot encode a native batch", 1, true), encode_err)

        assert.is_true(session:finish({ ok = true, result = { module = "app", staged = {} } }))
        assert.same({ kind = "result", ok = true, result = { module = "app", staged = {} } },
            receive(replies))
        -- The session closed its channel with that one result.
        local again, again_err = session:finish({ ok = true })
        assert.is_nil(again)
        assert.is_string(again_err)
    end)

    it("reports a result the record codec cannot carry as a failed build", function()
        local requests, replies = pipes()
        send(requests, compile_request({ module = "app" }))
        local session = assert(build_worker.connect(requests.read, replies.write))
        assert.is_true(session:finish({ ok = true, result = { callback = function() end } }))
        local record = receive(replies)
        assert.equal("result", record.kind)
        assert.is_false(record.ok)
        assert.is_nil(record.result)
        assert.equal(1, #record.diagnostics)
        assert.truthy(record.diagnostics[1]:find("^cannot encode the build result: "), record.diagnostics[1])
    end)

    it("notices the coordinator closing its end without blocking", function()
        local requests, replies = pipes()
        send(requests, compile_request({ module = "app" }))
        local session = assert(build_worker.connect(requests.read, replies.write))
        assert.is_false(session:abandoned())
        assert.is_false(session:abandoned())
        close_requests(requests)
        local polls = 0
        while not session:abandoned() do
            polls = polls + 1
            assert.truthy(polls < 1000, "coordinator EOF was never observed")
            uv.sleep(1)
        end
        session.control:close()
    end)

    it("rejects a missing, broken or incompatible compile request", function()
        local protocol = version.BUILD_WORKER_PROTOCOL
        local function rejected(write)
            local requests, replies = pipes()
            write(requests)
            local session, err = build_worker.connect(requests.read, replies.write)
            assert.is_nil(session)
            return err
        end
        local incompatible = "incompatible build coordinator request (expected protocol " ..
            tostring(protocol) .. ")"
        for _, record in ipairs({
            { kind = "compile", protocol = "titan-build-worker-v0", request = {} },
            { kind = "native", protocol = protocol, request = {} },
            { kind = "compile", protocol = protocol, request = "app" },
        }) do
            assert.equal(incompatible, rejected(function(requests) send(requests, record) end))
        end
        local closed = "cannot read the build request: the build coordinator closed the control channel"
        assert.equal(closed, rejected(close_requests))
        assert.equal(closed, rejected(function(requests)
            -- End of file inside a record.
            write_bytes(requests, string.pack(">I4", 64) .. "partial")
            close_requests(requests)
        end))
        assert.equal("cannot read the build request: control record of 4294967295 bytes exceeds its bound",
            rejected(function(requests) write_bytes(requests, "\255\255\255\255") end))
        local garbled = rejected(function(requests)
            write_bytes(requests, process.frame("\0not a control record"))
        end)
        assert.truthy(garbled:find("^cannot read the build request: "), garbled)
        assert.equal("cannot read the build request: control record is not a table",
            rejected(function(requests)
                write_bytes(requests, process.frame(assert(process.encode_record("compile"))))
            end))

        -- Descriptors that are not open cannot carry a control channel.
        local dead = assert(uv.pipe())
        uv.fs_close(dead.read)
        uv.fs_close(dead.write)
        local session, err = build_worker.connect(dead.read, dead.write)
        assert.is_nil(session)
        assert.truthy(err:find("^cannot open the build control channel: "), err)
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
-- the coordinator, output, results, malformed records, scripted protocol
-- violations, and orphan behavior.
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

local function wait_for(path)
    while true do
        local file = io.open(path, "rb")
        if file then file:close(); return end
        process.library().sleep(10)
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
    if request.truncated then
        -- A length prefix announcing more bytes than ever arrive.
        session.control.pipe:write("\0\0\0\32truncated", function()
            os.exit(0)
        end)
        process.library().run()
    end
    if request.steps then
        -- Scripted records, waits for a marker file, a pid file for jobs that
        -- outlive this worker, signals and exits. A rejected record makes the
        -- coordinator terminate this worker while it waits for a reply.
        for _, step in ipairs(request.steps) do
            if step.wait then
                wait_for(step.wait)
            elseif step.pidfile then
                local file = assert(io.open(step.pidfile, "wb"))
                assert(file:write(string.format("%d", process.library().os_getpid())))
                assert(file:close())
            elseif step.exit then
                os.exit(step.exit)
            elseif step.signal then
                local uv = process.library()
                uv.kill(uv.os_getpid(), step.signal)
                uv.sleep(5000)
            else
                assert(session.control:send(step.raw or assert(process.encode_record(step.send))))
            end
        end
        session.control:receive()
        os.exit(0)
    end
    if request.progress_records then
        -- Frontend phase records a progress-enabled coordinator asked for.
        for _, record in ipairs(request.progress_records) do
            assert(session:progress(record.phase, record.detail))
        end
    end
    counter(request, "enter")
    local ok = request.ok ~= false
    if request.batch_wait then wait_for(request.batch_wait) end
    for _, batch in ipairs(request.batches or {}) do
        counter(request, "leave")
        local results, failure, cancelled = session:run_batch(batch)
        counter(request, "enter")
        local outcomes = {}
        for index = 1, #batch do
            local result = results and results[index]
            outcomes[index] = result and (result.ok and "true" or "failed:" .. tostring(result.code)) or
                "unstarted"
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
    if request.exit_after_finish then os.exit(request.exit_after_finish) end
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

-- Scheduler nodes from { name, { dependency names } } in plan order.
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

-- Certification and request preparation run in the coordinator itself; no
-- worker process starts in these cases.
describe("module build scheduler decisions", function()
    it("decides a module unblocked by a certified dependency in plan order", function()
        local decided = {}
        local scheduler = build.new_scheduler(graph({ { "a", { "b" } }, { "b" }, { "c" } }), {
            decide = function(node)
                decided[#decided + 1] = node.name
                return "done"
            end,
        })
        assert.is_true(scheduler:run())
        -- c was already queued when b's hit unblocked a, which precedes it.
        assert.same({ "b", "a", "c" }, decided)
        assert.equal(0, scheduler.started)
    end)

    it("stops certifying after an internal error and skips the module's dependents", function()
        local decided = {}
        local nodes = graph({ { "a" }, { "b", { "a" } }, { "c" } })
        local ok, diagnostics = build.new_scheduler(nodes, {
            decide = function(node)
                decided[#decided + 1] = node.name
                if node.name == "a" then error("certificate reader crashed", 0) end
                return "done"
            end,
        }):run()
        assert.is_nil(ok)
        assert.same({ "a" }, decided)
        assert.same({
            "internal error while certifying module 'a': certificate reader crashed",
            "module certification stopped after an internal error",
        }, diagnostics)
        assert.equal("skipped", nodes[2].state)
    end)

    it("fails rejected modules and never reports an unbuilt plan as success", function()
        local nodes = graph({ { "rejected" }, { "dependent", { "rejected" } } })
        local ok, diagnostics = build.new_scheduler(nodes, {
            decide = function() return "fail" end,
        }):run()
        assert.is_nil(ok)
        assert.same({ "module 'rejected' cannot be built" }, diagnostics)
        assert.equal("skipped", nodes[2].state)

        -- A failure that carries no diagnostic of its own still fails.
        ok, diagnostics = build.new_scheduler(graph({ { "quiet" } }), {
            decide = function() return "fail", {} end,
        }):run()
        assert.is_nil(ok)
        assert.same({ "module 'quiet' was not built" }, diagnostics)

        -- Members of a dependency cycle never become decidable.
        ok, diagnostics = build.new_scheduler(graph({ { "a", { "b" } }, { "b", { "a" } } }), {
            decide = function() error("a cycle member must not be decided") end,
        }):run()
        assert.is_nil(ok)
        assert.same({ "modules with unresolved dependencies: a, b" }, diagnostics)
    end)

    it("fails a module whose worker request cannot be prepared or encoded without starting a worker", function()
        local nodes = graph({ { "unprepared" }, { "raising" }, { "unencodable" },
            { "dependent", { "unprepared" } } })
        local scheduler = build.new_scheduler(nodes, {
            decide = function() return "build" end,
            request = function(node, jobs_bound)
                assert.equal(2, jobs_bound)
                if node.name == "unprepared" then return nil, "cannot retire the committed object" end
                if node.name == "raising" then error("plan descriptor crashed", 0) end
                return { module = node.name, callback = function() end }
            end,
            complete = function() error("nothing is published") end,
        }, { jobs = 2, makeflags = false })
        local ok, diagnostics = scheduler:run()
        assert.is_nil(ok)
        assert.equal(0, scheduler.started)
        assert.equal(3, #diagnostics)
        assert.equal("cannot retire the committed object", diagnostics[1])
        assert.equal("internal error while preparing module 'raising': plan descriptor crashed",
            diagnostics[2])
        assert.truthy(diagnostics[3]:find("^cannot encode the build request of module 'unencodable': "),
            diagnostics[3])
        assert.equal("skipped", nodes[4].state)
    end)
end)

-- build.lock_outputs taken by this process; a second open file description
-- of the same lock file stands in for another invocation's attempt.
describe("output-tree locks in this process", function()
    local support = require "titan"
    local util = require "titan-compiler.util"
    local strategy = compiler_io.new_sync()
    local workspace
    before_each(function() workspace = new_workspace() end)
    after_each(function() remove_tree(workspace) end)

    local function lockable(path)
        local probe = assert(support._output_lock_open(path))
        local held = probe:try()
        probe:close()
        return held
    end

    it("creates missing output directories and locks each physical directory once", function()
        local nested, other = workspace .. "/out/release/objects", workspace .. "/other"
        assert(lfs.mkdir(other))
        local locks = assert(build.lock_outputs(strategy, { nested, other, other .. "/." }))
        assert.equal("directory", lfs.attributes(nested, "mode"))
        assert.equal(2, #locks.entries)
        -- Acquired in physical identity order, whatever the request order.
        assert.is_true(util.bytewise_less(locks.entries[1].identity, locks.entries[2].identity))
        for _, entry in ipairs(locks.entries) do assert.is_false(lockable(entry.path)) end
        assert.is_true(locks:release())
        assert.is_true(locks:release())
        assert.is_true(lockable(nested .. "/" .. build.LOCK_NAME))
        assert.is_true(lockable(other .. "/" .. build.LOCK_NAME))
    end)

    it("accepts an output directory another invocation created first", function()
        local raced = workspace .. "/raced"
        local racing = setmetatable({
            mkdir = function(_, path)
                -- Another invocation wins between this one's stat and mkdir.
                assert(lfs.mkdir(path))
                return strategy:mkdir(path)
            end,
        }, { __index = strategy })
        local locks = assert(build.lock_outputs(racing, { raced }))
        assert.is_false(lockable(raced .. "/" .. build.LOCK_NAME))
        assert.is_true(locks:release())
    end)

    it("names an output path that is not a directory or cannot become one", function()
        local file = workspace .. "/file"
        write_file(file, "not a directory")
        local requested = file .. "/out"
        -- The offending parent is reported in the platform's own spelling;
        -- Windows normalizes separators in the observed path.
        local parent = platform.windows and assert(platform.path.normalize(file)) or file
        local locks, err = build.lock_outputs(strategy, { workspace .. "/fine", requested })
        assert.is_nil(locks)
        assert.equal("cannot lock output directory '" .. requested .. "': '" .. parent ..
            "' is not a directory", err)
        if not platform.windows then
            -- A dangling link occupies the name without being a directory.
            local dangling = workspace .. "/dangling"
            assert(lfs.link(workspace .. "/absent", dangling, true))
            locks, err = build.lock_outputs(strategy, { dangling })
            assert.is_nil(locks)
            assert.truthy(err:find("cannot lock output directory '" .. dangling .. "': ", 1, true), err)
        end
    end)

    it("refuses to build unlocked without the native lock support", function()
        local saved = package.loaded.titan
        local stale, missing = {}, {}
        local ran, failure = pcall(function()
            -- An older installed runtime without the lock entry point.
            package.loaded.titan = {}
            stale = table.pack(build.lock_outputs(strategy, { workspace }))
            package.loaded.titan = nil
            -- require appends every searched path; only the first line is reported.
            package.preload.titan = function()
                error("titan runtime is not installed\n\tno file 'titan.so'", 0)
            end
            missing = table.pack(build.lock_outputs(strategy, { workspace }))
        end)
        package.preload.titan = nil
        package.loaded.titan = saved
        assert.is_true(ran, failure)
        assert.is_nil(stale[1])
        assert.equal("the installed Titan native support library lacks _output_lock_open; reinstall Titan",
            stale[2])
        assert.is_nil(missing[1])
        assert.equal("cannot load the Titan native support library: titan runtime is not installed",
            missing[2])
        assert.is_nil(lfs.attributes(workspace .. "/" .. build.LOCK_NAME))
    end)

    it("waits for another invocation and relocks a lock file replaced meanwhile", function()
        if platform.windows then pending("Windows denies removing an open build lock"); return end
        local process = require "titan-compiler.process"
        local uv = process.library()
        local tree = workspace .. "/tree"
        local lock_path = tree .. "/" .. build.LOCK_NAME
        local ready, waiting = workspace .. "/holder.ready", workspace .. "/waiter.waiting"
        assert(lfs.mkdir(tree))
        write_file(workspace .. "/holder.lua", string.format([[
package.path = %q
package.cpath = %q
local build = require "titan-compiler.build"
local uv = require("titan-compiler.process").library()
local locks = assert(build.lock_outputs(require("titan-compiler.io").new_sync(), { %q }))
assert(assert(io.open(%q, "wb")):close())
for _ = 1, 3000 do
    local file = io.open(%q, "rb")
    if file then file:close(); break end
    uv.sleep(10)
end
-- The tree is replaced while this invocation still holds its old lock file.
assert(os.remove(%q))
os.exit(0)
]], package.path, package.cpath, tree, ready, waiting, lock_path))
        local holder = assert(process.start({ assert(uv.exepath()), "-E", workspace .. "/holder.lua" }))
        for _ = 1, 1000 do
            if exists(ready) then break end
            uv.sleep(10)
        end
        local written, restore = capture_stderr(function()
            -- Released only once this invocation has announced that it waits.
            if not exists(waiting) then write_file(waiting, "waiting\n") end
        end)
        local ran, locks, err = pcall(build.lock_outputs, strategy, { tree }, { verbose = true })
        restore()
        local holder_ok, holder_term, holder_code = holder:wait()
        assert.is_true(ran, locks)
        assert.truthy(locks, err)
        assert.is_true(holder_ok, tostring(holder_term) .. " " .. tostring(holder_code))
        assert.same({ "titanc: waiting for build lock '" .. lock_path .. "'\n" }, written)
        local entry = locks.entries[1]
        assert.is_true(entry.lock:linked(lock_path))
        local probe = assert(support._output_lock_open(lock_path))
        assert.equal(entry.identity, probe:identity())
        assert.is_false(probe:try())
        probe:close()
        assert.is_true(locks:release())
        assert.is_true(lockable(lock_path))
    end)
end)

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
                local request = requests[node.name] or {}
                if request.publish_marker then write_file(request.publish_marker, "published\n") end
                if request.publish_raise then error(request.publish_raise, 0) end
                if request.publish_error then return nil, request.publish_error end
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

    it("accepts worker progress records without replying and without a reporter", function()
        local reporter = { calls = {} }
        function reporter:plan(total)
            self.calls[#self.calls + 1] = "plan " .. tostring(total)
        end
        function reporter:module_begin(name)
            self.calls[#self.calls + 1] = "begin " .. name
        end
        function reporter:module_phase(name, phase, detail)
            self.calls[#self.calls + 1] = "phase " .. name .. " " .. tostring(phase) ..
                (detail and (" " .. detail) or "")
        end
        function reporter:module_done(name)
            self.calls[#self.calls + 1] = "done " .. name
        end
        function reporter:module_failed(name)
            self.calls[#self.calls + 1] = "failed " .. name
        end
        function reporter:up_to_date(name)
            self.calls[#self.calls + 1] = "hit " .. name
        end
        function reporter:write(text)
            if type(text) == "string" and text ~= "" then
                self.calls[#self.calls + 1] = "write " .. text
            end
        end

        local ok, diagnostics = run(graph({ { "a" } }), {
            a = { progress_records = {
                { phase = "parsing" },
                { phase = "compiling C", detail = "2 parts" },
            } },
        }, { jobs = 2, progress = reporter })
        assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
        assert.same({
            "begin a",
            "phase a parsing",
            "phase a compiling C 2 parts",
            "done a",
        }, reporter.calls)
        -- A plain reporter also owns the replayed worker output.
        assert.same({}, captured)

        -- Without a reporter the records are ignored and never fail the module.
        captured = {}
        local quiet, quiet_diagnostics = run(graph({ { "b" } }), {
            b = { progress_records = { { phase = "parsing" } } },
        }, { jobs = 2 })
        assert.is_true(quiet, quiet_diagnostics and table.concat(quiet_diagnostics, "\n"))
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

    it("fails a module for each control record outside the protocol", function()
        local function native(id, batch) return { kind = "native", id = id, jobs = batch } end
        local valid = { argv = { "true" }, stdout = workspace .. "/valid.out", stderr = workspace .. "/valid.err" }
        local result = { kind = "result", ok = true, result = {} }
        local ok, diagnostics, signo, record = run(graph({
            { "bad_id" }, { "empty_argv" }, { "nul_argument" }, { "unknown_kind" },
            { "two_results" }, { "undecodable" }, { "truncated" },
        }), {
            bad_id = { steps = { { send = native("first", { valid }) } } },
            empty_argv = { steps = { { send = native(1, { { argv = {}, stdout = "o", stderr = "e" } }) } } },
            nul_argument = { steps = { { send = native(1, {
                valid, { argv = { "cc\0" }, stdout = "o", stderr = "e" },
            }) } } },
            unknown_kind = { steps = { { send = { kind = "timetable" } } } },
            two_results = { steps = { { send = result }, { send = result } } },
            undecodable = { steps = { { raw = "\0not a control record" } } },
            truncated = { truncated = true },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.is_nil(signo)
        local function failed(module, reason)
            return "build worker for module '" .. module .. "' failed: " .. reason
        end
        assert.equal(7, #diagnostics, table.concat(diagnostics, "\n"))
        assert.equal(failed("bad_id", "unexpected native batch request"), diagnostics[1])
        assert.equal(failed("empty_argv", "malformed native job 1"), diagnostics[2])
        assert.equal(failed("nul_argument", "malformed native job 2"), diagnostics[3])
        assert.equal(failed("unknown_kind", "unknown control record kind timetable"), diagnostics[4])
        assert.equal(failed("two_results", "unexpected result record"), diagnostics[5])
        assert.truthy(diagnostics[6]:find(failed("undecodable", "invalid control record: "), 1, true),
            diagnostics[6])
        assert.equal(failed("truncated", "control channel ended inside a record"), diagnostics[7])
        -- No rejected batch ran, and nothing was published.
        assert.falsy(exists(workspace .. "/valid.out"))
        assert.same({}, record.completed)
    end)

    it("reports a worker that dies before its result or exits nonzero after it", function()
        local ok, diagnostics, _, record = run(graph({ { "killed" }, { "late_exit" } }), {
            killed = { steps = { { signal = "sigkill" } } },
            late_exit = { exit_after_finish = 5 },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.same({
            "build worker for module 'killed' was terminated by signal 9 without reporting a result",
            "build worker for module 'late_exit' exited with status 5 after reporting its result",
        }, diagnostics)
        assert.same({}, record.completed)
        -- The reported result's staged files are discarded, not published.
        assert.same({ "late_exit" }, record.discarded)
    end)

    -- A job that marks its start and then outlives the worker whose pid the
    -- pid file names: it finishes only once that worker has been reaped, so
    -- the coordinator has seen the worker end before the job ends.
    local function outliving_job(marker, name, pidfile)
        local script = ': > "$1"; i=0; ' ..
            'while [ ! -s "$2" ] && [ "$i" -lt 2000 ]; do sleep 0.01; i=$((i + 1)); done; pid=$(cat "$2"); ' ..
            'while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 4000 ]; do sleep 0.01; i=$((i + 1)); done; ' ..
            'echo "$3" >> "$4"'
        return {
            argv = { "sh", "-c", script, "outliving", marker, pidfile, name, state .. "/jobs" },
            stdout = workspace .. "/" .. name .. ".out", stderr = workspace .. "/" .. name .. ".err",
        }
    end

    it("drops only the queued native jobs of a worker that exits mid-batch", function()
        local pidfile = workspace .. "/quitter.pid"
        local quitter_started, steady_started = workspace .. "/quitter.started", workspace .. "/steady.started"
        local ok, diagnostics, _, record = run(graph({ { "quitter" }, { "steady" } }), {
            quitter = { steps = {
                { pidfile = pidfile },
                { send = { kind = "native", id = 1, jobs = {
                    outliving_job(quitter_started, "quitter-first", pidfile),
                    job("quitter-second", 0), job("quitter-third", 0) } } },
                -- Both batches are registered once both first jobs run.
                { wait = quitter_started },
                { wait = steady_started },
                { exit = 4 },
            } },
            steady = { batches = { {
                outliving_job(steady_started, "steady-first", pidfile), job("steady-second", 0),
            } } },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.same({ "build worker for module 'quitter' exited with status 4 without reporting a result" },
            diagnostics)
        assert.same({ "steady" }, record.completed)
        -- The exited worker's running job finished and its queued jobs never
        -- started; the other worker's job queued behind it still ran.
        local ran = lines(state .. "/jobs")
        table.sort(ran)
        assert.same({ "quitter-first", "steady-first", "steady-second" }, ran)
    end)

    it("abandons a running batch when its worker breaks the protocol", function()
        local pidfile, started = workspace .. "/breaker.pid", workspace .. "/first.started"
        local ok, diagnostics = run(graph({ { "breaker" } }), {
            breaker = { steps = {
                { pidfile = pidfile },
                { send = { kind = "native", id = 1, jobs = {
                    outliving_job(started, "first", pidfile), job("second", 0) } } },
                { wait = started },
                { send = { kind = "result", ok = true, result = { module = "breaker" } } },
            } },
        }, { jobs = 1 })
        assert.is_nil(ok)
        assert.same({ "build worker for module 'breaker' failed: unexpected result record" }, diagnostics)
        assert.same({ "first" }, lines(state .. "/jobs"))
    end)

    it("reports a native job that cannot start like a shell that cannot execute it", function()
        local missing = workspace .. "/missing-tool"
        local ok, diagnostics = run(graph({ { "m" } }), {
            m = { batches = { { { argv = { missing, "-c" }, stdout = workspace .. "/m.out",
                stderr = workspace .. "/m.err" } } } },
        }, { jobs = 2 })
        assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
        assert.truthy(table.concat(lines(log), "\n"):find("batch m failed:127 nil nil", 1, true),
            table.concat(lines(log), "\n"))
        local errors = read_file(workspace .. "/m.err")
        assert.truthy(errors:find("^titanc: cannot start '" .. missing:gsub("%p", "%%%0") .. "': "), errors)
    end)

    it("fails a module whose publication fails and skips its dependents", function()
        local ok, diagnostics, _, record = run(graph({ { "a" }, { "b" }, { "c", { "a" } } }), {
            a = { publish_error = "cannot rename the staged object" },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.same({ "cannot rename the staged object" }, diagnostics)
        assert.same({ "b" }, record.completed)
        table.sort(record.requested)
        assert.same({ "a", "b" }, record.requested)
    end)

    it("answers a later native batch as stopped after an internal publication error", function()
        local published = workspace .. "/a.published"
        local ok, diagnostics, signo, record = run(graph({ { "a" }, { "b" } }), {
            a = { publish_raise = "publisher crashed", publish_marker = published },
            b = { batch_wait = published, batches = { { job("never", 0) } } },
        }, { jobs = 2 })
        assert.is_nil(ok)
        assert.is_nil(signo)
        assert.same({
            "internal error while publishing module 'a': publisher crashed",
            "module publication stopped after an internal error",
        }, diagnostics)
        assert.same({}, record.completed)
        assert.truthy(table.concat(lines(log), "\n"):find(
            "batch b unstarted the module build stopped after an earlier failure nil", 1, true),
            table.concat(lines(log), "\n"))
        assert.falsy(exists(state .. "/jobs"))
    end)

    it("starts no worker when another job ledger owns the cancellation guard", function()
        local jobs = require "titan-compiler.jobs"
        local outer = assert(jobs.open_slots(2, { makeflags = false }))
        local ran, ok, diagnostics, signo, record = pcall(run, graph({ { "a" } }), {}, { jobs = 2 })
        assert(outer:close())
        assert.is_true(ran, ok)
        assert.is_nil(ok)
        assert.is_nil(signo)
        assert.equal(0, record.scheduler.started)
        assert.same({}, record.requested)
        assert.equal(1, #diagnostics)
        assert.truthy(diagnostics[1]:find("already active", 1, true), diagnostics[1])
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

        it("waits on the pool and wakes when another client returns a token", function()
            -- Take both tokens, so the second job can start only after the
            -- first returns one as another client of the same Make would.
            assert.equal(2, #holder:read(2))
            -- The first job returns a token, then keeps its own slot until the
            -- second job has run on that token (bounded, so a coordinator that
            -- never wakes fails the order assertion instead of hanging).
            local first = {
                argv = { "sh", "-c", 'printf x > "$1"; i=0; ' ..
                    'until grep -qx second "$2" 2>/dev/null || [ "$i" -ge 1000 ]; do sleep 0.01; i=$((i + 1)); done; ' ..
                    'echo first >> "$2"', "returner", fifo, state .. "/jobs" },
                stdout = workspace .. "/first.out", stderr = workspace .. "/first.err",
            }
            local ok, diagnostics = run(graph({ { "m" } }), {
                m = { batches = { { first, job("second", 0) } } },
            }, { jobs = 8, makeflags = "-j3 --jobserver-auth=fifo:" .. fifo })
            assert.is_true(ok, diagnostics and table.concat(diagnostics, "\n"))
            -- The second job ran on the returned token while the first still ran.
            assert.same({ "second", "first" }, lines(state .. "/jobs"))
            -- Exactly the borrowed byte went back to the pool.
            assert.equal(1, available())
            assert.equal("x", holder:read(1))
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

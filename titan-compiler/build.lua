-- Compiler-owned module builds for one titanc invocation (issue #303 C1/C5).
-- The coordinator plans the requested source closure, certifies unchanged
-- modules in-process without parsing them, runs one short-lived worker
-- process (titan-compiler.build_worker) per remaining module under a single
-- job-slot ledger, and is the only publisher of their outputs. It also owns
-- the output-tree lock that serializes invocations sharing outputs.
-- Implementation notes: doc/implementation/driver.md#compiler-owned-module-builds
local jobs = require "titan-compiler.jobs"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"
local process = require "titan-compiler.process"
local util = require "titan-compiler.util"
local version = require "titan-compiler.version"

local build = {}

build.LOCK_NAME = ".titan-build.lock"
build.WORKER_ENTRY = "titan-compiler.build_worker"

local LOCK_POLL_MILLISECONDS = 50

local function native_support(names)
    local called, support = pcall(require, "titan")
    if not called or type(support) ~= "table" then
        return nil, "cannot load the Titan native support library: " ..
            tostring(support)
    end
    for _, name in ipairs(names) do
        if type(support[name]) ~= "function" then
            return nil, "the installed Titan native support library lacks " ..
                name .. "; reinstall Titan"
        end
    end
    return support
end

local function append_all(list, items)
    if type(items) == "table" then
        for _, item in ipairs(items) do list[#list + 1] = tostring(item) end
    elseif items ~= nil then
        list[#list + 1] = tostring(items)
    end
    return list
end

-- Create `directory` and missing parents through the resolver strategy.
local function ensure_directory(strategy, directory)
    local info = strategy:stat(directory)
    if info then
        if info.kind ~= "directory" then
            return nil, "'" .. directory .. "' is not a directory"
        end
        return true
    end
    local parent = platform.parent(directory)
    if parent and parent ~= "" and parent ~= directory then
        local made, err = ensure_directory(strategy, parent)
        if not made then return nil, err end
    end
    local made, err = strategy:mkdir(directory)
    if not made then
        -- Another invocation may have created it meanwhile.
        local again = strategy:stat(directory)
        if again and again.kind == "directory" then return true end
        return nil, err
    end
    return true
end

--
-- Output-tree coordination
--

local LockSet = {}
LockSet.__index = LockSet

-- Idempotent. Process death releases the locks too.
function LockSet:release()
    for index = #self.entries, 1, -1 do self.entries[index].lock:close() end
    self.entries = {}
    return true
end

-- POSIX descriptors each build worker inherits, so an orphaned worker of a
-- dead coordinator keeps the trees locked until it has exited.
function LockSet:descriptors()
    local descriptors = {}
    for _, entry in ipairs(self.entries) do
        descriptors[#descriptors + 1] = entry.lock:descriptor()
    end
    return descriptors
end

-- One exclusive OS lock per output domain for the whole invocation, taken
-- before anything is certified: `<directory>/.titan-build.lock` in each
-- directory (created when missing). Spellings of one directory converge on
-- the lock file's physical identity, and every invocation acquires its locks
-- in identity order, so overlapping domain sets cannot deadlock. Waiting
-- polls without holding Make tokens; ordinary Lua interruption ends it. A
-- failure is an error, never an unlocked build. Returns the lock set, or nil
-- and an error.
function build.lock_outputs(strategy, directories, options)
    options = options or {}
    local support, support_err = native_support({ "_output_lock_open" })
    if not support then return nil, support_err end
    local set = setmetatable({ entries = {} }, LockSet)
    local function fail(directory, err)
        set:release()
        return nil, "cannot lock output directory '" .. tostring(directory) ..
            "': " .. tostring(err)
    end
    local seen = {}
    for _, directory in ipairs(directories) do
        local ready, ready_err = ensure_directory(strategy, directory)
        if not ready then return fail(directory, ready_err) end
        local path = platform.join(directory, build.LOCK_NAME)
        local lock, err = support._output_lock_open(path)
        if not lock then return fail(directory, err) end
        local identity = lock:identity()
        if seen[identity] then
            lock:close()
        else
            seen[identity] = true
            set.entries[#set.entries + 1] = {
                directory = directory, path = path, lock = lock, identity = identity,
            }
        end
    end
    table.sort(set.entries, function(left, right)
        return util.bytewise_less(left.identity, right.identity)
    end)
    for _, entry in ipairs(set.entries) do
        local announced = false
        while true do
            local held, err = entry.lock:try()
            if held == nil then return fail(entry.directory, err) end
            if held then
                if entry.lock:linked(entry.path) then break end
                -- The tree was removed and recreated while this invocation
                -- waited; the lock now lives in the new file.
                entry.lock:close()
                local reopened, reopen_err = support._output_lock_open(entry.path)
                if not reopened then return fail(entry.directory, reopen_err) end
                entry.lock, entry.identity = reopened, reopened:identity()
            else
                if options.verbose and not announced then
                    announced = true
                    pcall(io.stderr.write, io.stderr,
                        "titanc: waiting for build lock '" .. entry.path .. "'\n")
                end
                process.library().sleep(LOCK_POLL_MILLISECONDS)
            end
        end
    end
    return set
end

--
-- Import discovery
--

local function import_list(imports)
    local result, seen = {}, {}
    for _, import in ipairs(imports) do
        local previous = seen[import.name]
        if previous then
            previous.source_required = previous.source_required or
                import.source_required == true
        else
            local entry = { name = import.name, source_required = import.source_required == true }
            seen[import.name] = entry
            result[#result + 1] = entry
        end
    end
    return result
end

-- Direct imports of one planned source module, for graph discovery only:
-- the certified record's saved list while its own sources match, else a
-- lexical scan of every constituent in canonical order, else the full
-- parser. A syntax error yields no imports; the module's worker then reports
-- the ordinary parser diagnostic. Returns the ordered list, or nil and an
-- error when a constituent cannot be read.
function build.imports_for(strategy, source, certified)
    if certified and type(certified.imports) == "table" then
        return import_list(certified.imports)
    end
    local found = {}
    local files = source.files or { source.main }
    for index, file in ipairs(files) do
        local contents = index == 1 and source.contents or nil
        if not contents then
            local read_err
            contents, read_err = strategy:read_file(file)
            if not contents then
                return nil, "cannot read source '" .. tostring(file) .. "': " ..
                    tostring(read_err)
            end
        end
        local imports = parser.scan_imports(contents)
        if not imports then
            local nodes = parser.parse(file, contents)
            if not nodes then return {} end
            imports = {}
            for _, node in ipairs(nodes) do
                if node._tag == "Ast.TopLevelImport" then
                    imports[#imports + 1] = {
                        name = node.modname, source_required = node.source_required,
                    }
                end
            end
        end
        for _, import in ipairs(imports) do found[#found + 1] = import end
    end
    return import_list(found)
end

--
-- Scheduler
--

local SETTLED = { done = true, failed = true, skipped = true }

local Scheduler = {}
Scheduler.__index = Scheduler

-- `nodes`: array in plan order of { name, deps = { node, ... } }.
-- `hooks.decide(node) -> "done" | "build" | "fail", text` certifies in-process
-- once every dependency is done (a hit is restored there); it may buffer
-- verbose lines in `node.stderr`.
-- `hooks.request(node, jobs) -> data | nil, err` prepares a miss for its
-- worker; `jobs` is the slot bound its native batches see.
-- `hooks.complete(node, result) -> true | nil, err` publishes a result.
-- `hooks.discard(node, result)` (optional) removes the staged files of a
-- successful result that a stopped build will not publish.
-- options: jobs (the local cap), makeflags (overrides MAKEFLAGS),
-- worker_entry (the worker's main module), locks (lock set to inherit).
-- `scheduler.started` counts the workers started.
function build.new_scheduler(nodes, hooks, options)
    local scheduler = setmetatable({
        nodes = nodes, hooks = hooks, options = options or {},
        ready = {}, native_queue = {}, decisions = {}, workers = {},
        live_workers = 0, running_native = 0, cursor = 1,
        diagnostics = {}, failures = {}, started = 0, events = {},
        resume_queue = {},
    }, Scheduler)
    for index, node in ipairs(nodes) do
        node.index = index
        node.state = "waiting"
        node.stdout, node.stderr, node.messages = {}, {}, {}
        node.dependents = {}
    end
    for _, node in ipairs(nodes) do
        local unique = {}
        for _, dep in ipairs(node.deps or {}) do
            if dep ~= node and not unique[dep] then
                unique[dep] = true
                dep.dependents[#dep.dependents + 1] = node
            end
        end
        node.remaining = 0
        for _ in pairs(unique) do node.remaining = node.remaining + 1 end
    end
    for _, node in ipairs(nodes) do
        if node.remaining == 0 then scheduler:queue_decision(node) end
    end
    return scheduler
end

-- Decisions run in plan order through an explicit work list (long chains of
-- certified hits do not nest calls).
function Scheduler:queue_decision(node)
    local queue = self.decisions
    local position = #queue + 1
    while position > 1 and queue[position - 1].index > node.index do
        position = position - 1
    end
    table.insert(queue, position, node)
end

function Scheduler:fatal(message)
    self.failures[#self.failures + 1] = message
    self:stop()
end

function Scheduler:fail(node, diagnostics)
    node.state = "failed"
    append_all(node.messages, diagnostics)
    -- Dependents can never be built in this invocation; the causal
    -- diagnostic is the dependency's own.
    local pending = { node }
    while #pending > 0 do
        local current = table.remove(pending)
        for _, dependent in ipairs(current.dependents) do
            if dependent.state == "waiting" then
                dependent.state = "skipped"
                pending[#pending + 1] = dependent
            end
        end
    end
end

function Scheduler:complete(node)
    node.state = "done"
    for _, dependent in ipairs(node.dependents) do
        dependent.remaining = dependent.remaining - 1
        if dependent.remaining == 0 and dependent.state == "waiting" then
            self:queue_decision(dependent)
        end
    end
end

function Scheduler:insert_ready(node)
    local ready = self.ready
    local position = #ready + 1
    while position > 1 and
          util.bytewise_less(node.name, ready[position - 1].name) do
        position = position - 1
    end
    table.insert(ready, position, node)
end

function Scheduler:drain_decisions()
    while not self.stopped and #self.decisions > 0 do
        local node = table.remove(self.decisions, 1)
        if node.state == "waiting" then
            node.state = "deciding"
            local called, decision, detail = pcall(self.hooks.decide, node)
            if not called then
                self:fail(node, "internal error while certifying module '" ..
                    node.name .. "': " .. tostring(decision))
                self:fatal("module certification stopped after an internal error")
            elseif decision == "done" then
                self:complete(node)
            elseif decision == "build" then
                node.state = "ready"
                self:insert_ready(node)
            else
                self:fail(node, detail or ("module '" .. node.name ..
                    "' cannot be built"))
            end
        end
    end
end

function Scheduler:release_slot()
    local released, err = self.ledger:release()
    if not released then
        self:fatal("failed to return a jobserver token: " .. tostring(err))
    end
end

-- The interpreter and module path this process runs with, never a PATH
-- launcher: workers load exactly the compiler the coordinator loaded.
local function worker_argv(entry)
    local interpreter, err = process.library().exepath()
    if not interpreter then
        return nil, "cannot locate the running Lua interpreter: " .. tostring(err)
    end
    return { interpreter, "-E", "-e", string.format(
        "package.path = %q; package.cpath = %q; require(%q).main()",
        package.path, package.cpath, entry) }
end

local function exit_description(worker)
    if worker.signal and worker.signal ~= 0 then
        return "was terminated by signal " .. tostring(worker.signal)
    end
    return "exited with status " .. tostring(worker.code)
end

function Scheduler:start_worker(node)
    local function abandon(message)
        self:release_slot()
        self:fail(node, message)
    end
    if not self.argv then
        local argv, argv_err = worker_argv(self.options.worker_entry or build.WORKER_ENTRY)
        if not argv then return abandon(argv_err) end
        self.argv = argv
    end
    local called, request, request_err = pcall(self.hooks.request, node, self.ledger.limit)
    if not called or not request then
        return abandon(called and request_err or ("internal error while preparing module '" ..
            node.name .. "': " .. tostring(request)))
    end
    local payload, encode_err = process.encode_record({
        kind = "compile", protocol = version.BUILD_WORKER_PROTOCOL, request = request,
    })
    if not payload then
        return abandon("cannot encode the build request of module '" .. node.name ..
            "': " .. tostring(encode_err))
    end
    local worker = { node = node, lease = true }
    local child, err = process.start_worker(self.argv, {
        inherit = self.options.locks and self.options.locks:descriptors() or nil,
    }, {
        record = function(record_payload)
            self:defer("worker_record", worker, record_payload)
        end,
        failed = function(failure) self:defer("worker_failed", worker, failure) end,
        exited = function(code, signal)
            self:defer("worker_exited", worker, code, signal)
        end,
        settled = function() self:defer("worker_settled", worker) end,
    })
    if not child then
        return abandon("cannot start the build worker for module '" .. node.name ..
            "': " .. tostring(err))
    end
    worker.process = child
    node.state = "running"
    self.live_workers = self.live_workers + 1
    self.started = self.started + 1
    self.workers[#self.workers + 1] = worker
    if worker.failure then
        child:kill("sigterm")
        return
    end
    local sent, send_err = child:send(payload)
    if not sent then self:worker_failed(worker, send_err) end
end

function Scheduler:worker_failed(worker, failure)
    if worker.failure then return end
    worker.failure = failure
    local batch = worker.batch
    if batch then
        batch.abandoned = true
        self:drop_queued(function(job) return job.batch == batch end)
    end
    if worker.process then worker.process:kill("sigterm") end
end

local function valid_job(job)
    if type(job) ~= "table" or type(job.argv) ~= "table" or #job.argv == 0 or
       type(job.stdout) ~= "string" or type(job.stderr) ~= "string" then
        return false
    end
    for index, word in pairs(job.argv) do
        if math.type(index) ~= "integer" or index < 1 or index > #job.argv or
           type(word) ~= "string" or word:find("\0", 1, true) then
            return false
        end
    end
    return true
end

local function dense_count(list)
    if type(list) ~= "table" then return nil end
    local count = 0
    for index in pairs(list) do
        if math.type(index) ~= "integer" or index < 1 then return nil end
        count = count + 1
    end
    return count == #list and count or nil
end

function Scheduler:reply(worker, batch)
    local payload, err = process.encode_record({
        kind = "native-result", id = batch.id, results = batch.results,
        failure = batch.failure, cancelled = batch.cancelled,
    })
    local sent
    if payload then sent, err = worker.process:send(payload) end
    if not sent then self:worker_failed(worker, "cannot answer a native batch: " .. tostring(err)) end
end

function Scheduler:worker_record(worker, payload)
    if worker.failure then return end
    local record, err = process.decode_record(payload)
    if not record then
        return self:worker_failed(worker, "invalid control record: " .. tostring(err))
    end
    if record.kind == "native" then
        local count = dense_count(record.jobs)
        if worker.batch or not worker.lease or worker.result or
           math.type(record.id) ~= "integer" or not count then
            return self:worker_failed(worker, "unexpected native batch request")
        end
        for index = 1, count do
            if not valid_job(record.jobs[index]) then
                return self:worker_failed(worker, "malformed native job " .. index)
            end
        end
        local batch = { worker = worker, id = record.id, results = {},
            queued = 0, running = 0 }
        if count == 0 then return self:reply(worker, batch) end
        if self.stopped then
            -- Nothing new starts; the worker keeps its slot and finishes.
            return self:reply_stopped(worker, batch)
        end
        worker.batch = batch
        -- The first job inherits the frontend's slot; the others queue for
        -- ordinary slots ahead of modules that have not started yet.
        worker.lease = false
        for index = 2, count do
            batch.queued = batch.queued + 1
            self.native_queue[#self.native_queue + 1] = {
                batch = batch, index = index, spec = record.jobs[index],
            }
        end
        self:start_native({ batch = batch, index = 1, spec = record.jobs[1] })
    elseif record.kind == "result" then
        if worker.result or worker.batch then
            return self:worker_failed(worker, "unexpected result record")
        end
        worker.result = record
    else
        self:worker_failed(worker, "unknown control record kind " .. tostring(record.kind))
    end
end

local function append_log(path, text)
    local file = io.open(path, "ab")
    if file then
        file:write(text)
        file:close()
    end
end

-- Runs one native job on a slot it already holds.
function Scheduler:start_native(job)
    local batch = job.batch
    batch.running = batch.running + 1
    self.running_native = self.running_native + 1
    local child, err = process.start_job(job.spec.argv, job.spec.stdout, job.spec.stderr,
        function(ok, term, code) self:defer("native_done", job, ok, term, code) end)
    if not child then
        -- Reported like a shell that could not execute the command.
        append_log(job.spec.stderr, "titanc: cannot start '" .. job.spec.argv[1] ..
            "': " .. tostring(err) .. "\n")
        self:native_done(job, nil, "exit", 127)
    end
end

-- After a stop the reply says why: the worker's driver then fails the
-- module, removes its own temporaries and exits without a publication.
function Scheduler:reply_stopped(worker, batch)
    batch.cancelled = self.cancelled
    if not self.cancelled then
        batch.failure = "the module build stopped after an earlier failure"
    end
    self:reply(worker, batch)
end

function Scheduler:native_done(job, ok, term, code)
    local batch, worker = job.batch, job.batch.worker
    batch.results[job.index] = { ok = ok, term = term, code = code }
    batch.running = batch.running - 1
    self.running_native = self.running_native - 1
    local finished = batch.running == 0 and batch.queued == 0
    if finished and worker.batch == batch then worker.batch = nil end
    if finished and not batch.abandoned and not worker.exited and
       not worker.failure then
        -- The batch's last slot becomes the frontend's slot again.
        worker.lease = true
        if self.stopped then self:reply_stopped(worker, batch)
        else self:reply(worker, batch) end
    else
        self:release_slot()
    end
end

function Scheduler:drop_queued(predicate)
    local kept = {}
    for _, job in ipairs(self.native_queue) do
        if predicate(job) then
            job.batch.queued = job.batch.queued - 1
        else
            kept[#kept + 1] = job
        end
    end
    self.native_queue = kept
end

function Scheduler:worker_exited(worker, code, signal)
    worker.exited, worker.code, worker.signal = true, code, signal
    if worker.lease then
        worker.lease = false
        self:release_slot()
    end
    local batch = worker.batch
    if batch then
        batch.abandoned = true
        self:drop_queued(function(job) return job.batch == batch end)
        if batch.running == 0 then worker.batch = nil end
    end
end

function Scheduler:worker_settled(worker)
    local node = worker.node
    self.live_workers = self.live_workers - 1
    append_all(node.stdout, worker.process.stdout)
    append_all(node.stderr, worker.process.stderr)
    local record = worker.result
    local prefix = "build worker for module '" .. node.name .. "'"
    if self.stopped and record and record.ok == true and self.hooks.discard then
        -- A stopped build publishes nothing more; its staged files go.
        pcall(self.hooks.discard, node, record.result)
    end
    if worker.failure then
        self:fail(node, prefix .. " failed: " .. worker.failure)
    elseif self.stopped then
        self:fail(node, {})
    elseif not record then
        self:fail(node, prefix .. " " .. exit_description(worker) ..
            " without reporting a result")
    elseif record.ok ~= true then
        local messages = {}
        append_all(messages, record.diagnostics)
        if #messages == 0 then messages[1] = prefix .. " reported a failure" end
        self:fail(node, messages)
    elseif worker.code ~= 0 or (worker.signal or 0) ~= 0 then
        if self.hooks.discard then pcall(self.hooks.discard, node, record.result) end
        self:fail(node, prefix .. " " .. exit_description(worker) ..
            " after reporting its result")
    else
        local called, completed, err = pcall(self.hooks.complete, node, record.result)
        if not called then
            self:fail(node, "internal error while publishing module '" .. node.name ..
                "': " .. tostring(completed))
            self:fatal("module publication stopped after an internal error")
        elseif not completed then
            self:fail(node, err)
        else
            self:complete(node)
        end
    end
end

-- Under the slot ledger: workers waiting to resume after a batch, then
-- queued native jobs (their modules already run), then ready modules in
-- bytewise order. A stopped build only resumes workers so they can finish.
function Scheduler:dispatch()
    self.want_slot = false
    while #self.resume_queue > 0 or (not self.stopped and
            (#self.native_queue > 0 or #self.ready > 0)) do
        local granted, err = self.ledger:acquire_nowait()
        if granted == nil then
            self:fatal("failed to acquire a jobserver token: " .. tostring(err))
            if #self.resume_queue == 0 then break end
            -- A worker that cannot resume would wait forever: end it.
            for _, worker in ipairs(self.resume_queue) do
                self:worker_failed(worker, "no job slot to resume after a stopped build")
            end
            self.resume_queue = {}
            break
        elseif not granted then
            self.want_slot = true
            break
        end
        if #self.resume_queue > 0 then
            local worker = table.remove(self.resume_queue, 1)
            if worker.exited or worker.failure then
                self:release_slot()
            else
                worker.lease = true
                self:reply_stopped(worker, worker.stopped_batch)
            end
        elseif #self.native_queue > 0 then
            local job = table.remove(self.native_queue, 1)
            job.batch.queued = job.batch.queued - 1
            self:start_native(job)
        else
            self:start_worker(table.remove(self.ready, 1))
        end
    end
    self:update_token_poll()
end

function Scheduler:update_token_poll()
    local descriptor = self.want_slot and
        self.ledger.token_descriptor and self.ledger:token_descriptor() or nil
    if descriptor then
        local uv = process.library()
        if self.token_poll and self.token_descriptor ~= descriptor then
            self.token_poll:close()
            self.token_poll, self.token_polling = nil, false
        end
        if not self.token_poll then
            self.token_poll = uv.new_poll(descriptor)
            self.token_descriptor = descriptor
        end
        if not self.token_polling then
            self.token_polling = true
            self.token_poll:start("r", function()
                self.token_poll:stop()
                self.token_polling = false
            end)
        end
    elseif self.token_polling then
        self.token_poll:stop()
        self.token_polling = false
    end
end

-- Stop starting modules and queued native work. Live workers are not
-- killed: like running native jobs they drain, so their children finish and
-- their temporaries are removed. A batch left with nothing running is
-- answered as stopped once its worker has a slot again; a later batch
-- request is answered at once (its worker kept its slot).
function Scheduler:stop()
    if self.stopped then return end
    self.stopped = true
    local emptied = {}
    for _, job in ipairs(self.native_queue) do
        job.batch.queued = job.batch.queued - 1
        emptied[job.batch] = true
    end
    self.native_queue = {}
    for _, worker in ipairs(self.workers) do
        local batch = worker.batch
        if batch and emptied[batch] and batch.running == 0 and
           not batch.abandoned and not worker.exited and not worker.failure then
            worker.batch = nil
            worker.stopped_batch = batch
            self.resume_queue[#self.resume_queue + 1] = worker
        end
    end
end

function Scheduler:cancel(signo)
    if self.cancelled then return end
    self.cancelled = signo
    self:stop()
end

-- Event-loop callbacks only queue their event; the main loop handles them,
-- so publication and certification never run inside a luv callback (where
-- another uv.run, such as a Windows captured command, would re-enter).
function Scheduler:defer(method, ...)
    self.events[#self.events + 1] = table.pack(method, ...)
end

function Scheduler:process_events()
    while #self.events > 0 do
        local event = table.remove(self.events, 1)
        self[event[1]](self, table.unpack(event, 2, event.n))
    end
end

function Scheduler:watch_signals()
    local uv = process.library()
    if platform.windows then
        self.signal_handles = {}
        for name, number in pairs({ sigint = 2, sighup = 1, sigbreak = 21 }) do
            local handle = uv.new_signal()
            if handle and handle:start(name, function() self:defer("cancel", number) end) then
                self.signal_handles[#self.signal_handles + 1] = handle
            elseif handle then
                handle:close()
            end
        end
        return
    end
    local descriptor = self.ledger:signal_descriptor()
    if descriptor then
        self.signal_poll = uv.new_poll(descriptor)
        self.signal_poll:start("r", function()
            local signo = self.ledger:cancelled()
            if signo then
                self.signal_poll:stop()
                self:defer("cancel", signo)
            end
        end)
    end
end

function Scheduler:close_handles()
    for _, name in ipairs({ "token_poll", "signal_poll" }) do
        local handle = self[name]
        if handle and not handle:is_closing() then handle:close() end
    end
    for _, handle in ipairs(self.signal_handles or {}) do
        if not handle:is_closing() then handle:close() end
    end
    self.token_poll, self.signal_poll, self.signal_handles = nil, nil, nil
    process.library().run("nowait")
end

function Scheduler:busy()
    if self.live_workers > 0 or self.running_native > 0 or #self.events > 0 or
       #self.resume_queue > 0 then
        return true
    end
    if self.stopped then return false end
    return #self.ready > 0 or #self.native_queue > 0 or #self.decisions > 0
end

local function write_stream(stream, chunks)
    if #chunks == 0 then return end
    pcall(stream.write, stream, table.concat(chunks))
    pcall(stream.flush, stream)
end

-- Buffered output and diagnostics leave in plan order, never in completion
-- order: each settled node in turn, stopping at the first unsettled one.
function Scheduler:flush(node)
    if node.flushed then return end
    node.flushed = true
    write_stream(io.stdout, node.stdout)
    write_stream(io.stderr, node.stderr)
    append_all(self.diagnostics, node.messages)
end

function Scheduler:emit()
    while self.cursor <= #self.nodes do
        local node = self.nodes[self.cursor]
        if not SETTLED[node.state] then break end
        self:flush(node)
        self.cursor = self.cursor + 1
    end
end

local function check_scheduler_support()
    if platform.windows then return true end
    return native_support({ "_signal_wake_descriptor" })
end

-- Run every node to completion. Returns true, or nil, the diagnostics in
-- plan order, and the INT/TERM/HUP signal that cancelled the build (which
-- the caller re-raises after its own cleanup).
function Scheduler:run()
    self:drain_decisions()
    if #self.ready > 0 then
        local supported, support_err = check_scheduler_support()
        local ledger, ledger_err
        if supported then
            ledger, ledger_err = jobs.open_slots(self.options.jobs or 1, {
                guard = true, makeflags = self.options.makeflags,
            })
        end
        if not ledger then
            self:fatal(tostring(support_err or ledger_err))
        else
            self.ledger = ledger
            self:watch_signals()
            while true do
                self:process_events()
                self:drain_decisions()
                self:dispatch()
                self:emit()
                if not self:busy() then break end
                process.library().run("once")
            end
            self:close_handles()
            local closed, close_err = ledger:close()
            if not closed then self.failures[#self.failures + 1] = tostring(close_err) end
            self.cancelled = self.cancelled or ledger:cancelled()
        end
    end
    self:emit()
    local unsettled = {}
    for _, node in ipairs(self.nodes) do
        if not SETTLED[node.state] then unsettled[#unsettled + 1] = node.name end
        self:flush(node)
    end
    append_all(self.diagnostics, self.failures)
    if self.cancelled then
        self.diagnostics[#self.diagnostics + 1] =
            "module build interrupted by signal " .. tostring(self.cancelled)
    elseif #unsettled > 0 and #self.failures == 0 then
        self.diagnostics[#self.diagnostics + 1] =
            "modules with unresolved dependencies: " .. table.concat(unsettled, ", ")
    end
    if #self.diagnostics > 0 or self.cancelled then
        return nil, self.diagnostics, self.cancelled
    end
    for _, node in ipairs(self.nodes) do
        if node.state ~= "done" then
            return nil, { "module '" .. node.name .. "' was not built" }
        end
    end
    return true
end

--
-- The titanc entry point
--

local function miss_line(context, node, reason, detail)
    if not context.probe_verbose then return end
    node.stderr[#node.stderr + 1] = "Titan object miss " .. node.name .. ": " ..
        tostring(reason or "no-object") ..
        (detail ~= nil and detail ~= "" and (" " .. tostring(detail)) or "") .. "\n"
end

-- Build the requested closure. `request`: roots (ordered), loader_options
-- (the ordinary loader options), incremental, test, coverage, c_parts,
-- pretty_print, verbose, jobs (the local cap), locks (the invocation's
-- lock set from build.lock_outputs). On success every source module of the
-- closure is restored into driver.imported and the resolver context is
-- finalized. Returns true, or nil, diagnostics and the cancelling signal.
function build.run(context, request)
    local driver = require "titan-compiler.driver"
    local incremental = request.incremental and require "titan-compiler.incremental"

    local loader_options = {}
    for key, value in pairs(request.loader_options or {}) do loader_options[key] = value end
    loader_options.context = context
    loader_options.plan_mode = true
    loader_options.imports_for = function(_, source, certified)
        return build.imports_for(context.io, source, certified)
    end
    local loader = driver.defaultloader({}, loader_options)
    local diagnostics = {}
    for _, root in ipairs(request.roots) do
        local ok, err = loader(root)
        if not ok then append_all(diagnostics, err) end
    end
    if #diagnostics > 0 then return nil, diagnostics end
    local plan, plan_err = driver.resolution_plan(context)
    if not plan then return nil, append_all({}, plan_err) end

    local nodes, by_name = {}, {}
    for _, name in ipairs(plan.order) do
        local module = plan.modules[name]
        if module and module.kind == "source" and not by_name[name] then
            local node = { name = name, module = module, deps = {} }
            nodes[#nodes + 1] = node
            by_name[name] = node
        end
    end
    for _, node in ipairs(nodes) do
        -- Members of an import cycle do not wait: their workers report the
        -- ordinary circular-import diagnostic.
        if not node.module.cyclic then
            for _, import in ipairs(node.module.imports or {}) do
                local dep = by_name[import.name]
                if dep then node.deps[#node.deps + 1] = dep end
            end
        end
    end

    local configuration

    local function decide(node)
        local module = node.module
        if module.error then return "fail", module.error end
        if not incremental or module.cyclic then return "build" end
        local certified = module.certified
        if not certified or certified.status ~= "hit" then
            miss_line(context, node, certified and certified.reason, certified and certified.detail)
            return "build"
        end
        local verdict = incremental.verdict(certified.record, plan)
        if verdict.status == "hit" then
            local entry, code, detail =
                driver.restore_source_object(context, node.name, module.source, certified)
            if entry then
                plan.update(node.name, certified)
                return "done"
            elseif entry == nil then
                miss_line(context, node, code, detail)
                return "build"
            end
            return "fail", code
        elseif verdict.status == "miss" then
            miss_line(context, node, verdict.reason, verdict.detail)
        else
            -- Every dependency is final by now, so a pending verdict cannot
            -- be satisfied later; rebuilding is the safe answer.
            miss_line(context, node, "dependency-unavailable",
                table.concat(verdict.names or {}, ", "))
        end
        return "build"
    end

    -- Right before the worker starts: retire the committed object (primary
    -- first), then hand the worker the closed plan data.
    local function request_for(node, jobs_bound)
        local invalidated, invalidate_err =
            driver.invalidate_source_object(context, node.name, node.module.source)
        if not invalidated then return nil, invalidate_err end
        if not configuration then
            local configuration_err
            configuration, configuration_err = driver.worker_configuration(context)
            if not configuration then return nil, configuration_err end
        end
        return {
            module = node.name,
            configuration = configuration,
            options = {
                plan = driver.plan_descriptor(plan, node.name),
                c_parts = request.c_parts,
                test = request.test,
                coverage = request.coverage,
                pretty_print = request.pretty_print,
                verbose = request.verbose,
                jobs = jobs_bound,
            },
        }
    end

    local function complete(node, result)
        local certified, err = driver.publish_staged_module(context, result)
        if not certified then return nil, err end
        plan.update(node.name, certified)
        local entry, code, detail = driver.restore_source_object(
            context, node.name, node.module.source, certified, { published = true })
        if not entry then
            return nil, "cannot load module '" .. node.name ..
                "' after publishing it: " .. tostring(code) ..
                (detail and (" " .. tostring(detail)) or "")
        end
        return true
    end

    -- A result the stopped build will not publish: remove its staged objects.
    local function discard(_, result)
        for _, staged in ipairs(type(result) == "table" and result.staged or {}) do
            if type(staged) == "table" and type(staged.from) == "string" and
               context.io:lstat(staged.from) then
                context.io:unlink(staged.from)
            end
        end
    end

    local scheduler = build.new_scheduler(nodes, {
        decide = decide, request = request_for, complete = complete,
        discard = discard,
    }, {
        jobs = request.jobs, locks = request.locks,
    })
    local built, build_diagnostics, signo = scheduler:run()
    if not built then return nil, build_diagnostics, signo end
    local finalized, finalize_errors = driver.finalize_resolver_context(context)
    if not finalized then return nil, append_all({}, finalize_errors) end
    return true
end

return build

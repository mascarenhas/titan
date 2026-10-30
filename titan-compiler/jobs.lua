-- Native job scheduling shared by generated-C compilation, provider links,
-- the C probe batch and the build coordinator (titan-compiler.build): the
-- job-slot ledger that participates in a parent GNU Make jobserver, the
-- completion channel, the background launcher, the launch/reap loop, and the
-- build-worker executor that sends a worker's batches to its coordinator.
-- Implementation notes: doc/implementation/driver.md#parallel-generated-c-compilation
local platform = require "titan-compiler.platform"

local jobs = {}

-- The batch caller assigns each prepared module its original request index;
-- every job inherits it as its owning module index.
function jobs.set_request_index(prepared, request_index)
    prepared.request_index = request_index
    for _, job in ipairs(prepared.jobs) do job.module_index = request_index end
end

-- Flatten every prepared module's native jobs while retaining ownership.
-- `ordinal` is original module/part result and diagnostic order. The caller
-- assigns completion identities by position in the sorted launch schedule.
function jobs.flatten(prepared)
    local entries, results = {}, {}
    for module_position, compilation in ipairs(prepared) do
        local module_result = { jobs = {} }
        results[module_position] = module_result
        for job_position, job in ipairs(compilation.jobs) do
            entries[#entries + 1] = {
                ordinal = #entries + 1,
                job = job,
                job_position = job_position,
                module_result = module_result,
            }
        end
    end
    return entries, results
end

function jobs.record(entry, ok, err, code)
    entry.module_result.jobs[entry.job_position] = {
        ok = ok, err = err, code = code,
    }
end

-- A module succeeds only when every part compiled. Its error is the first
-- failing part's, in part order; every part's result remains in `jobs`.
function jobs.summarize(results)
    for _, result in ipairs(results) do
        result.ok = true
        for _, job_result in ipairs(result.jobs) do
            if result.ok and not job_result.ok then
                result.ok = nil
                result.err, result.code = job_result.err, job_result.code
            end
        end
    end
    return results
end

-- Largest estimated cost first; ties keep the original module request
-- order and then part order, so the launch sequence is deterministic.
function jobs.launch_order(entries)
    local schedule = {}
    for index, entry in ipairs(entries) do schedule[index] = entry end
    table.sort(schedule, function(left, right)
        local left_cost = left.job.cost_bytes or 0
        local right_cost = right.job.cost_bytes or 0
        if left_cost ~= right_cost then return left_cost > right_cost end
        local left_module = left.job.module_index or 0
        local right_module = right.job.module_index or 0
        if left_module ~= right_module then return left_module < right_module end
        local left_part = left.job.part_index or 0
        local right_part = right.job.part_index or 0
        if left_part ~= right_part then return left_part < right_part end
        return left.ordinal < right.ordinal
    end)
    return schedule
end

-- MAKEFLAGS words, honoring GNU Make's backslash escapes. Option words end at
-- the standalone "--" that precedes command-line variable assignments.
local function makeflags_words(makeflags)
    local words, current, escaped = {}, {}, false
    for index = 1, #makeflags do
        local char = makeflags:sub(index, index)
        if escaped then
            current[#current + 1] = char
            escaped = false
        elseif char == "\\" then
            escaped = true
        elseif char:match("%s") then
            if #current ~= 0 then
                words[#words + 1] = table.concat(current)
                current = {}
            end
        else
            current[#current + 1] = char
        end
    end
    if #current ~= 0 then words[#words + 1] = table.concat(current) end
    return words
end

local function descriptor(text)
    return math.tointeger(tonumber(text))
end

-- The job policy a parent Make advertised to this process. `auth` is the
-- last jobserver authorization (`--jobserver-auth=fifo:PATH`,
-- `--jobserver-auth=R,W`, or legacy `--jobserver-fds=R,W`); `serial` means
-- an explicit `-j1` without a jobserver.
function jobs.make_policy(makeflags)
    local policy = { serial = false }
    if type(makeflags) ~= "string" then return policy end
    local job_word
    for _, word in ipairs(makeflags_words(makeflags)) do
        if word == "--" then break end
        local value = word:match("^%-%-jobserver%-auth=(.*)$") or
            word:match("^%-%-jobserver%-fds=(.*)$")
        if value then
            local fifo = value:match("^fifo:(.+)$")
            local read_text, write_text = value:match("^(%-?%d+),(%-?%d+)$")
            local read_fd = read_text and descriptor(read_text)
            local write_fd = write_text and descriptor(write_text)
            if fifo then
                policy.auth = { kind = "fifo", path = fifo, text = value }
            elseif read_fd and write_fd then
                policy.auth = { kind = "pipe", read = read_fd,
                    write = write_fd, text = value }
            else
                policy.auth = { kind = "invalid", text = value }
            end
        elseif word:match("^%-j%d*$") then
            job_word = word
        end
    end
    policy.serial = policy.auth == nil and job_word == "-j1"
    return policy
end

local REQUIRED_SUPPORT = {
    "_jobserver_open", "_jobserver_wait", "_signal_guard",
    "_signal_pending", "_signal_raise",
}

local function native_support()
    local called, support = pcall(require, "titan")
    if not called or type(support) ~= "table" then
        return nil, "cannot load the Titan native support library: " ..
            tostring(support):match("^[^\n]*")
    end
    for _, name in ipairs(REQUIRED_SUPPORT) do
        if type(support[name]) ~= "function" then
            return nil, "the installed Titan native support library lacks " ..
                name .. "; reinstall Titan"
        end
    end
    return support
end

local warned_unusable = false

local function warn_unusable(auth, reason)
    if warned_unusable then return end
    warned_unusable = true
    pcall(io.stderr.write, io.stderr,
        "titanc: warning: the parent make jobserver (" .. auth.text ..
        ") is unusable: " .. tostring(reason) ..
        "; running native compiler jobs one at a time (mark the recipe with " ..
        "'+' or use GNU Make 4.4's FIFO jobserver)\n")
end

local warned_local_cap = false

-- A live progress frame drawn during a native wait is a courtesy: the child it
-- is drawing over still owns the transaction. The ledger drops its hook as
-- soon as a frame fails, so this runs once per ledger and a broken renderer is
-- never retried ten times a second.
local function warn_idle(reason)
    pcall(io.stderr.write, io.stderr,
        "titanc: warning: the live progress frame failed: " ..
        tostring(reason) .. "; native job waits no longer draw frames\n")
end

-- The single policy for a valid inherited pipe jobserver that this platform
-- cannot reopen privately (stock macOS Make 3.81): titanc keeps its own local
-- --jobs/TITAN_JOBS bound and takes no part in the parent's pool. It neither
-- changes the flags of the parent's shared pipe descriptions nor reads
-- tokens through a blocking helper thread. Sharing a parent pool requires
-- GNU Make 4.4's FIFO jobserver or Linux's private reopen (maintainer
-- decision for issue #303). Returns the bound to use.
function jobs.unshareable_pipe_limit(local_cap, auth, reason)
    if not warned_local_cap then
        warned_local_cap = true
        pcall(io.stderr.write, io.stderr,
            "titanc: warning: the parent make jobserver (" .. auth.text ..
            ") cannot be shared on this platform: " .. tostring(reason) ..
            "; using titanc's own job bound of " .. tostring(local_cap) ..
            " (GNU Make 4.4's FIFO jobserver shares the parent's pool)\n")
    end
    return local_cap
end

-- Build-worker native execution (titan-compiler.build_worker). A worker owns
-- no ledger, jobserver client or signal guard: build_worker installs its
-- coordinator channel here, and each batch opened through open_slots,
-- open_channel, launch and drive becomes one request to the coordinator,
-- which owns the invocation's single slot ledger and starts, reaps and
-- reports every child. A synchronous io:run stays in the worker, under the
-- frontend slot the coordinator granted it.
-- `executor:run_batch(jobs)` takes { {argv, stdout, stderr}, ... } and
-- returns per-job { ok, term, code } (nil for a job it never started), the
-- transport failure text, and the cancelling signal number; it never raises
-- for a transport failure.
local remote

function jobs.use_remote(executor)
    remote = executor
end

function jobs.is_remote()
    return remote ~= nil
end

local RemoteSlots = {}
RemoteSlots.__index = RemoteSlots

function RemoteSlots:acquire_nowait()
    if self.active >= self.limit then return false end
    self.active = self.active + 1
    return true
end

function RemoteSlots:release()
    if self.active > 0 then self.active = self.active - 1 end
    return true
end

function RemoteSlots:cancelled() return self.cancelled_signal end

function RemoteSlots:close()
    self.active = 0
    return true
end

-- One job-slot ledger per native batch. The first active job uses the
-- implicit slot of the process that Make started; with a usable parent
-- jobserver every further concurrent job holds one borrowed token, so the
-- ledger holds exactly max(0, active - 1) exact token bytes.
local Slots = {}
Slots.__index = Slots

-- `local_cap` is the already-resolved local bound (--jobs > TITAN_JOBS > 4).
-- `options.makeflags` overrides the inherited MAKEFLAGS (for tests).
-- `options.guard` installs the cancellation guard even with one slot, for a
-- caller whose single job still runs as an asynchronous child.
-- `options.idle = { interval = <ms>, tick = <function> }` bounds every wait by
-- one interval and calls `tick` after each expiry, so a caller that owns a
-- live progress region keeps drawing frames while a native child runs. `wait`
-- never reports that expiry to its caller, and without the option every wait
-- blocks exactly as before.
function jobs.open_slots(local_cap, options)
    assert(math.type(local_cap) == "integer" and local_cap >= 1,
        "the local job cap must be a positive integer")
    options = options or {}
    local idle = options.idle
    if idle then
        assert(math.type(idle.interval) == "integer" and idle.interval >= 1 and
            type(idle.tick) == "function",
            "an idle progress hook needs a positive integer interval and a tick function")
    end
    if remote then
        return setmetatable({
            limit = local_cap, shared = false, active = 0, remote = remote,
        }, RemoteSlots)
    end
    local slots = setmetatable({
        limit = local_cap, shared = false, active = 0, idle = idle,
    }, Slots)
    -- Windows batches use luv processes; MSYS2 jobserver descriptors are not
    -- native UCRT descriptors, so only the local cap applies there.
    if platform.windows then return slots end
    local support, support_err = native_support()
    if not support then return nil, support_err end
    slots.support = support
    local makeflags = options.makeflags
    if makeflags == nil then makeflags = platform.getenv("MAKEFLAGS") end
    local policy = jobs.make_policy(makeflags)
    if policy.auth and local_cap > 1 then
        local client, reason, unsupported
        if policy.auth.kind == "fifo" then
            client, reason = support._jobserver_open("fifo", policy.auth.path)
        elseif policy.auth.kind == "pipe" then
            client, reason, unsupported = support._jobserver_open(
                "pipe", policy.auth.read, policy.auth.write)
        else
            reason = "unrecognized jobserver authorization"
        end
        if client then
            slots.client, slots.shared = client, true
        elseif unsupported == "unsupported" then
            slots.limit = jobs.unshareable_pipe_limit(local_cap, policy.auth, reason)
        else
            warn_unusable(policy.auth, reason)
            slots.limit = 1
        end
    elseif policy.serial then
        slots.limit = 1
    end
    if slots.limit > 1 or options.guard then
        local guard, guard_err = support._signal_guard()
        if not guard then
            if slots.client then slots.client:close() end
            return nil, guard_err
        end
        slots.guard = guard
    end
    return slots
end

-- true: a slot is now held (the implicit slot when none is active, else a
-- borrowed token, or a local slot without a jobserver); false: wait first.
function Slots:acquire_nowait()
    if self.active >= self.limit then return false end
    if self.active ~= 0 and self.client then
        local acquired, err = self.client:acquire()
        if acquired == nil then return nil, err end
        if not acquired then return false end
    end
    self.active = self.active + 1
    return true
end

-- After reaping a child, or after a failed launch: frees its slot and
-- returns one exact borrowed byte when more are held than active - 1.
function Slots:release()
    assert(self.active > 0, "no native job slot is active")
    self.active = self.active - 1
    if self.client and self.client:held() > math.max(self.active - 1, 0) then
        return self.client:release()
    end
    return true
end

-- Waits until the unbuffered completion FILE is readable ("completion"), a
-- token may be available ("slot", only when `want_slot`), or INT/TERM/HUP
-- arrived ("signal", signo). Nothing is consumed from the FILE.
--
-- With an idle hook every wait is bounded by its interval and one `tick` runs
-- per expiry, so the owner's live region draws a frame while a native child
-- runs; such an expiry is drawn, never returned. A failing `tick` is reported
-- once and then dropped: a broken frame must not fail, delay or otherwise
-- change the link it is drawing over, so the wait simply blocks again.
function Slots:wait(file, want_slot)
    if not self.support then return "completion" end
    local idle = self.idle
    while true do
        local client = want_slot and self.active < self.limit and self.client or nil
        local event, value = self.support._jobserver_wait(
            file, client, self.guard ~= nil and self.cancelled_signal == nil,
            idle and idle.interval)
        if event == "signal" then
            self.cancelled_signal = value
            return event, value
        end
        if event ~= "timeout" then return event, value end
        local drawn, draw_err = pcall(idle.tick)
        if not drawn then
            self.idle, idle = nil, nil
            warn_idle(draw_err)
        end
    end
end

function Slots:cancelled()
    if self.cancelled_signal == nil and self.guard then
        self.cancelled_signal = self.support._signal_pending()
    end
    return self.cancelled_signal
end

-- For an event loop that does its own waiting (titan-compiler.build): the
-- private parent-jobserver descriptor to poll for readability after
-- acquire_nowait returned false, and the cancellation guard's wake
-- descriptor. Either is nil when it does not apply.
function Slots:token_descriptor()
    if self.client and self.active > 0 and self.active < self.limit then
        return self.client:descriptor()
    end
end

function Slots:signal_descriptor()
    if self.guard then return self.support._signal_wake_descriptor() end
end

-- Returns every borrowed byte and restores the prior signal actions; call it
-- on every path. Idempotent. Afterwards `cancelled()` still reports a signal
-- the guard caught, which the caller must return to its owner.
function Slots:close()
    local ok, err = true, nil
    if self.client then
        ok, err = self.client:close()
        self.client = nil
    end
    self.active = 0
    if self.guard then
        local signo = self.guard:restore()
        self.guard = nil
        if signo and self.cancelled_signal == nil then self.cancelled_signal = signo end
    end
    return ok, err
end

-- After cleanup, deliver a recorded cancellation signal under the restored
-- action (Lua's SIGINT hook, or the default action).
function jobs.propagate(signo)
    if not signo or remote then return end
    local called, support = pcall(require, "titan")
    if called and type(support) == "table" and type(support._signal_raise) == "function" then
        support._signal_raise(signo)
    end
end

local function protected_remove(path)
    if not path then return true end
    local called, removed, remove_err = pcall(os.remove, path)
    if not called then return nil, removed end
    return removed, remove_err
end
jobs.protected_remove = protected_remove

local function shell_quote(word)
    return require("c-parser.cdriver").shell_quote(word)
end

local function execute_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        local word, err = shell_quote(argument)
        if not word then return nil, err end
        quoted[index] = word
    end
    return os.execute(table.concat(quoted, " "))
end

-- The completion channel of one native batch. POSIX: a private FIFO created
-- at the fresh temporary pathname returned by `reserve()`; each background
-- wrapper writes its completion index line after its command exited. Windows:
-- the bounded luv process batch, whose `read` returns the next index. In a
-- build worker: the list of requests that `drive` sends to the coordinator.
function jobs.open_channel(reserve)
    if remote then
        return {
            remote = true,
            requests = {},
            file = { close = function() return true end },
        }
    end
    if platform.windows then
        local batch, err = require("titan-compiler.process").new_batch()
        if not batch then return nil, err end
        return {
            batch = batch,
            file = {
                read = function() return batch:wait() end,
                close = function() return batch:close() end,
            },
        }
    end
    local path, path_err = reserve()
    if not path then return nil, path_err end
    local removed, remove_err = protected_remove(path)
    if not removed then
        return nil, "failed to prepare parallel compiler completion FIFO: " ..
            tostring(remove_err)
    end
    local made, term, code = execute_argv({ "mkfifo", "-m", "600", path })
    if not made then
        protected_remove(path)
        return nil, "failed to create parallel compiler completion FIFO" ..
            (code ~= nil and " (" .. tostring(term) .. ", exit " ..
                tostring(code) .. ")" or ": " .. tostring(term))
    end
    -- Linux and Darwin both define a read/write FIFO open to return without a
    -- peer. Keeping that descriptor's writer alive avoids blocking before the
    -- first worker and prevents a transient EOF while a slot is refilled.
    local open_called, file, open_err = pcall(io.open, path, "r+")
    if not open_called then
        protected_remove(path)
        return nil, file
    end
    if not file then
        protected_remove(path)
        return nil, open_err
    end
    -- The batch polls this descriptor before each read, so stdio read-ahead
    -- must never hold a completion line the kernel no longer reports.
    local unbuffered_called, unbuffered, unbuffered_err =
        pcall(file.setvbuf, file, "no")
    if not unbuffered_called or not unbuffered then
        pcall(file.close, file)
        protected_remove(path)
        return nil, "failed to make the parallel compiler completion FIFO " ..
            "unbuffered: " .. tostring(unbuffered_called and unbuffered_err or
                unbuffered)
    end
    local quoted_path, quote_err = shell_quote(path)
    if not quoted_path then
        pcall(file.close, file)
        protected_remove(path)
        return nil, quote_err
    end
    return {
        file = file,
        path = path,
        quoted_path = quoted_path,
    }
end

function jobs.close_channel(channel)
    local errors = {}
    local close_called, closed, close_err =
        pcall(channel.file.close, channel.file)
    if not close_called then
        errors[#errors + 1] = "close: " .. tostring(closed)
    elseif not closed then
        errors[#errors + 1] = "close: " .. tostring(close_err)
    end
    if channel.path then
        local removed, remove_err = protected_remove(channel.path)
        if not removed then
            errors[#errors + 1] = "remove: " .. tostring(remove_err)
        end
    end
    if #errors ~= 0 then
        return nil, "failed to clean parallel compiler completion " ..
            (platform.windows and "batch (" or "FIFO (") ..
            table.concat(errors, "; ") .. ")"
    end
    return true
end

-- Start one background command whose completion is reported on `channel`
-- as `completion_index`. POSIX runs the already quoted shell `command`;
-- Windows spawns `argv` directly. Standard output and error go to the two
-- caller-owned log files, or are merged in order when both paths are equal.
-- `before_start`, when given, runs after every fallible preparation step and
-- immediately before the child starts (the driver prints verbose commands
-- there). The caller removes its logs when this returns nil. A build worker
-- only records `argv` and the logs for its coordinator; `drive` sends them.
function jobs.launch(channel, argv, command, stdout_path, stderr_path,
                     completion_index, before_start, options)
    if channel.remote then
        if before_start then
            local ready, ready_err = before_start()
            if not ready then return nil, ready_err end
        end
        local process = { remote = true, finish_errors = {} }
        channel.requests[#channel.requests + 1] = {
            argv = argv, stdout = stdout_path, stderr = stderr_path,
            process = process,
        }
        return process
    end
    if platform.windows then
        if before_start then
            local ready, ready_err = before_start()
            if not ready then return nil, ready_err end
        end
        local called, launched, err = pcall(channel.batch.spawn,
            channel.batch, argv, stdout_path, stderr_path, completion_index)
        if not called or not launched then
            return nil, called and err or launched
        end
        return { pipe = launched }
    end
    local quoted_stdout, quote_err = shell_quote(stdout_path)
    if not quoted_stdout then return nil, quote_err end
    local stderr_redirect
    if stderr_path == stdout_path then
        stderr_redirect = "2>&1"
    else
        local quoted_stderr
        quoted_stderr, quote_err = shell_quote(stderr_path)
        if not quoted_stderr then return nil, quote_err end
        stderr_redirect = "2>" .. quoted_stderr
    end
    local quoted_index
    quoted_index, quote_err = shell_quote(tostring(completion_index))
    if not quoted_index then return nil, quote_err end
    if before_start then
        local ready, ready_err = before_start()
        if not ready then return nil, ready_err end
    end
    -- Both shells catch INT/TERM/HUP (exec resets caught signals, so the
    -- compiler keeps its default actions). A process-group signal therefore
    -- cannot end the wrapper before its compiler exits: reaping the wrapper
    -- proves the compiler's lifetime ended, and the completion is still sent.
    -- Keep the FIFO open read/write for this wrapper's lifetime too. If its
    -- coordinator dies, sending completion must not block on a missing reader
    -- and retain the writer's output locks forever. The compiler's stdout is
    -- separately redirected below, so only the completion line uses fd 1.
    local notified_command = "(trap : INT TERM HUP; " ..
        "(trap : INT TERM HUP; " .. command .. ") >" .. quoted_stdout ..
        " " .. stderr_redirect ..
        "; _titan_compile_status=$?; printf '%s\\n' " .. quoted_index ..
        "; exit $_titan_compile_status) 1<>" .. channel.quoted_path
    local started, pipe, start_error
    if options and options.inherit then
        -- Keep the same FIFO notification and status wrapper, but give the
        -- native writer the coordinator's close-on-exec lock descriptors.
        started, pipe, start_error = pcall(
            require("titan-compiler.process").start,
            { "/bin/sh", "-c", notified_command }, options)
    else
        started, pipe, start_error = pcall(io.popen, notified_command, "r")
    end
    if not started then return nil, pipe end
    if not pipe then return nil, start_error end
    return { pipe = pipe }
end

-- Wait for one launched child without throwing; records `ok`, `term` and
-- `code` exactly as `io.popen`'s close (or the Windows process wait) reports.
function jobs.reap(process)
    if process.remote then
        process.reaped = true
        return
    end
    process.finish_errors = {}
    local called, ok, term, code = pcall(process.pipe.close, process.pipe)
    if not called then
        process.finish_errors[#process.finish_errors + 1] =
            "reap: " .. tostring(ok)
        pcall(process.pipe.close, process.pipe)
        ok, term, code = nil, nil, nil
    end
    process.ok, process.term, process.code = ok, term, code
    process.reaped = true
end

-- A build worker's batch: every position is recorded in order (the caller's
-- size-descending schedule is the coordinator's start order), then sent as
-- one request. The coordinator starts a prefix of it, so a job it never
-- started carries an explanation instead of an exit status.
local function remote_drive(slots, channel, count, launch, launch_failed)
    local next_position, raised = count + 1, nil
    for position = 1, count do
        local called, process, launch_err = pcall(launch, position)
        if not called then
            raised = { error = process }
            next_position = position
            break
        end
        if not process then launch_failed(position, launch_err) end
    end
    local requests = channel.requests
    channel.requests = {}
    if #requests == 0 then return next_position, nil, nil, raised end
    local batch = {}
    for index, request in ipairs(requests) do
        batch[index] = {
            argv = request.argv, stdout = request.stdout, stderr = request.stderr,
        }
    end
    local called, results, failure, cancelled =
        pcall(slots.remote.run_batch, slots.remote, batch)
    if not called then
        raised = raised or { error = results }
        results, failure = nil, "the build coordinator request failed"
    end
    for index, request in ipairs(requests) do
        local process, result = request.process, results and results[index]
        if result then
            process.ok, process.term, process.code = result.ok, result.term, result.code
        else
            process.ok = nil
            process.finish_errors[#process.finish_errors + 1] = cancelled and
                ("not started: interrupted by signal " .. tostring(cancelled)) or
                ("not started: " .. tostring(failure or
                    "the build coordinator did not run it"))
        end
        process.reaped = true
    end
    slots.cancelled_signal = cancelled
    return next_position, failure, cancelled, raised
end

-- The launch/reap loop of one native batch over positions 1..count, launched
-- in order. `launch(position)` starts that position (it is also the
-- completion index) and returns its process record, or nil and an error;
-- `launch_failed(position, err)` records a failed launch. A slot is acquired
-- immediately before each launch and released only after its child was
-- reaped. After a channel failure, a caught signal or a raised `launch`, no
-- further position is launched and every running child is reaped directly.
-- Returns the first unlaunched position, the batch failure text (if any), the
-- signal that cancelled the batch (if any), and `{ error = object }` holding
-- what `launch` raised (if anything), which the caller rethrows unchanged
-- after its own cleanup. `label` names the children in failures.
function jobs.drive(slots, channel, count, launch, launch_failed, label)
    if channel.remote then
        return remote_drive(slots, channel, count, launch, launch_failed)
    end
    local pending, pending_count, next_position = {}, 0, 1
    local failure, cancelled, raised
    local function fail(message)
        failure = failure and (failure .. "; " .. message) or message
    end
    local function release_slot()
        local released, release_err = slots:release()
        if not released then
            fail("failed to return a jobserver token: " .. tostring(release_err))
        end
    end
    local function stopped() return failure or cancelled or raised end
    while (not stopped() and next_position <= count) or pending_count ~= 0 do
        -- Acquire immediately before each launch: the first active job uses
        -- this process's implicit slot, later ones borrow a token.
        local want_slot = false
        while not stopped() and next_position <= count do
            -- A pending signal wins over a simultaneous slot or completion
            -- event: check it before every acquisition and launch.
            cancelled = slots:cancelled()
            if cancelled then break end
            local granted, slot_err = slots:acquire_nowait()
            if granted == nil then
                fail("failed to acquire a jobserver token: " .. tostring(slot_err))
                break
            elseif not granted then
                want_slot = true
                break
            end
            local called, process, launch_err = pcall(launch, next_position)
            if not called then
                raised = { error = process }
                release_slot()
                break
            end
            if process then
                pending[next_position] = process
                pending_count = pending_count + 1
            else
                launch_failed(next_position, launch_err)
                release_slot()
            end
            next_position = next_position + 1
        end
        if pending_count ~= 0 then
            local completed, process
            if not stopped() then
                local wait_called, event, value = pcall(
                    slots.wait, slots, channel.file, want_slot)
                if not wait_called then event, value = nil, event end
                if event == "signal" then
                    cancelled = value
                elseif event == "completion" then
                    local read_called, line, read_err =
                        pcall(channel.file.read, channel.file, "*l")
                    if read_called then
                        completed = tonumber(line)
                        process = completed and pending[completed]
                    end
                    if not process then
                        fail("failed to receive " .. label .. " completion: " ..
                            tostring(read_called and (read_err or line) or line))
                    end
                elseif event ~= "slot" then
                    fail("failed to wait for " .. label .. " completion: " ..
                        tostring(value))
                end
            end
            -- After a completion-channel failure, a cancellation or a raised
            -- launch, reap tracked children directly instead of waiting for
            -- messages that may never arrive. Each wrapper exits only after
            -- its command.
            if stopped() and not process then
                for position = 1, count do
                    if pending[position] then
                        completed, process = position, pending[position]
                        break
                    end
                end
            end
            if process then
                pending[completed] = nil
                pending_count = pending_count - 1
                -- Return the slot only after the child is reaped.
                jobs.reap(process)
                release_slot()
            end
        end
    end
    return next_position, failure, cancelled, raised
end

return jobs

-- Native compile-job scheduling helpers shared by the driver's serial and
-- parallel object paths, and the job-slot ledger that participates in a
-- parent GNU Make jobserver.
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
-- `ordinal` is module/part order: the completion identity and the order in
-- which diagnostics are replayed and results are reported.
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
            tostring(support)
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
        "; compiling generated C with one job (mark the recipe with '+' " ..
        "or use GNU Make 4.4's FIFO jobserver)\n")
end

-- One job-slot ledger per native batch. The first active job uses the
-- implicit slot of the process that Make started; with a usable parent
-- jobserver every further concurrent job holds one borrowed token, so the
-- ledger holds exactly max(0, active - 1) exact token bytes.
local Slots = {}
Slots.__index = Slots

-- `local_cap` is the already-resolved local bound (--jobs > TITAN_JOBS > 4).
-- `options.makeflags` overrides the inherited MAKEFLAGS (for tests).
function jobs.open_slots(local_cap, options)
    assert(math.type(local_cap) == "integer" and local_cap >= 1,
        "the local job cap must be a positive integer")
    options = options or {}
    local slots = setmetatable({
        limit = local_cap, shared = false, active = 0,
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
        local client, reason
        if policy.auth.kind == "fifo" then
            client, reason = support._jobserver_open("fifo", policy.auth.path)
        elseif policy.auth.kind == "pipe" then
            client, reason = support._jobserver_open(
                "pipe", policy.auth.read, policy.auth.write)
        else
            reason = "unrecognized jobserver authorization"
        end
        if client then
            slots.client, slots.shared = client, true
        else
            warn_unusable(policy.auth, reason)
            slots.limit = 1
        end
    elseif policy.serial then
        slots.limit = 1
    end
    if slots.limit > 1 then
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
function Slots:wait(file, want_slot)
    if not self.support then return "completion" end
    local client = want_slot and self.active < self.limit and self.client or nil
    local event, value = self.support._jobserver_wait(
        file, client, self.guard ~= nil and self.cancelled_signal == nil)
    if event == "signal" then self.cancelled_signal = value end
    return event, value
end

function Slots:cancelled()
    if self.cancelled_signal == nil and self.guard then
        self.cancelled_signal = self.support._signal_pending()
    end
    return self.cancelled_signal
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
    if not signo then return end
    local called, support = pcall(require, "titan")
    if called and type(support) == "table" and type(support._signal_raise) == "function" then
        support._signal_raise(signo)
    end
end

return jobs

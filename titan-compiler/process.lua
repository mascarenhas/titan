-- Compiler process transport over the stock LuaRocks `luv` dependency:
-- Windows captured commands and native batches, and on every platform the
-- build coordinator's worker processes, their control channels, and the
-- native jobs the coordinator runs for them. Importing it does not load
-- native code.
-- Implementation notes: doc/implementation/driver.md#build-worker-transport
local platform = require "titan-compiler.platform"

local process = {}
local Process = {}
Process.__index = Process
local Batch = {}
Batch.__index = Batch
local Worker = {}
Worker.__index = Worker
local Control = {}
Control.__index = Control
local Frames = {}
Frames.__index = Frames
local uv

-- luv owns its native loop through its first module table. Anchor that table
-- for the process lifetime, so a host that restores package.loaded (Busted
-- between spec files) reuses the live loop instead of opening a second one.
local LUV_ANCHOR = "titan-compiler.process: luv"

local function library()
    if not uv then
        local registry = debug.getregistry()
        uv = registry[LUV_ANCHOR]
        if not uv then
            uv = require "luv"
            registry[LUV_ANCHOR] = uv
        end
    end
    return uv
end
process.library = library

-- Captured commands and native jobs run with the deterministic C locale;
-- `overrides` adds or (with false) removes variables. Windows names are
-- case-insensitive.
local function environment(overrides)
    local values, result = {}, {}
    local function key(name) return platform.windows and name:upper() or name end
    for name, value in pairs(uv.os_environ()) do
        values[key(name)] = name .. "=" .. value
    end
    for name, value in pairs(overrides or {}) do
        values[key(name)] = value ~= false and name .. "=" .. value or nil
    end
    values.LANG, values.LC_ALL = "LANG=C", "LC_ALL=C"
    for _, value in pairs(values) do result[#result + 1] = value end
    table.sort(result)
    return result
end

-- `options.inherit_environment` passes the parent's environment unchanged.
local function spawn(argv, stdio, options, completed)
    local child = setmetatable({}, Process)
    local arguments = {}
    for index = 2, #argv do arguments[#arguments + 1] = argv[index] end
    local handle, err = uv.spawn(argv[1], {
        args = arguments, stdio = stdio,
        cwd = options and options.cwd,
        env = not (options and options.inherit_environment) and
            environment(options and options.env) or nil,
    }, function(code, signal)
        child.code, child.signal = code, signal
        child.handle:close(function() child.closed = true end)
        if completed then completed(code, signal) end
    end)
    if not handle then return nil, err end
    child.handle = handle
    return child
end

-- io.popen-close shaped status of a reaped child.
local function exit_status(code, signal)
    if signal ~= 0 then return nil, "signal", signal end
    return code == 0 and true or nil, "exit", code
end

function Process:wait()
    while not self.closed do uv.run("once") end
    return exit_status(self.code, self.signal)
end
Process.close = Process.wait

function process.new_batch()
    library()
    return setmetatable({ children = {}, ready = {}, pending = 0 }, Batch)
end

-- Open the caller-owned logs of one child. Equal paths share one descriptor,
-- so the child's merged output keeps its write order (the C probe batch
-- captures diagnostics this way).
local function open_logs(stdout_path, stderr_path)
    local stdout, err = uv.fs_open(stdout_path, "w", 420)
    if not stdout then return nil, err end
    local stderr = stdout
    if stderr_path ~= stdout_path then
        stderr, err = uv.fs_open(stderr_path, "w", 420)
        if not stderr then uv.fs_close(stdout); return nil, err end
    end
    return stdout, stderr
end

local function close_logs(stdout, stderr)
    uv.fs_close(stdout)
    if stderr ~= stdout then uv.fs_close(stderr) end
end

function Batch:spawn(argv, stdout_path, stderr_path, completion_index)
    local stdout, stderr = open_logs(stdout_path, stderr_path)
    if not stdout then return nil, stderr end
    local child, err = spawn(argv, { nil, stdout, stderr }, nil, function()
        self.pending = self.pending - 1
        self.ready[#self.ready + 1] = completion_index
    end)
    close_logs(stdout, stderr)
    if not child then return nil, err end
    self.children[#self.children + 1] = child
    self.pending = self.pending + 1
    return child
end

function Batch:wait()
    while #self.ready == 0 do
        if self.pending == 0 then return nil, "no processes to wait for" end
        uv.run("once")
    end
    return table.remove(self.ready, 1)
end

function Batch:close()
    for _, child in ipairs(self.children) do child:wait() end
    self.children, self.ready = {}, {}
    uv.run("nowait") -- Also release handles from failed spawn attempts.
    return true
end

function process.capture(argv, options)
    library()
    options = options or {}
    local fds, err = uv.pipe({ nonblock = true })
    if not fds then return { started = false, ok = false, diagnostic = err } end
    local reader, chunks, drained = uv.new_pipe(), {}, false
    local opened
    opened, err = reader:open(fds.read)
    if not opened then
        uv.fs_close(fds.read)
        uv.fs_close(fds.write)
        reader:close()
        uv.run("nowait")
        return { started = false, ok = false, diagnostic = err }
    end
    local read_error
    opened, err = reader:read_start(function(read_err, data)
        if data then chunks[#chunks + 1] = data else
            read_error = read_err
            reader:close(function() drained = true end)
        end
    end)
    local child
    if opened then
        child, err = spawn(argv, { 0, fds.write,
            options.stderr_to_stdout == false and 2 or fds.write }, options)
    end
    uv.fs_close(fds.write)
    if not child then
        reader:close()
        uv.run("nowait")
        return { started = false, ok = false,
            diagnostic = "could not start captured command: " .. tostring(err) }
    end
    while not child.closed or not drained do uv.run("once") end
    local output = table.concat(chunks)
    if read_error then
        return { started = true, ok = false, output = output,
            diagnostic = output .. "\ncould not capture command output: " .. read_error }
    end
    local ok, why, status = child:wait()
    local signal = why == "signal" and status or nil
    return { started = true, ok = ok == true, output = output, diagnostic = output,
        status = status, why = why, signal = signal, interrupted = signal ~= nil }
end

-- One native job the build coordinator runs for a worker: `argv` spawned
-- directly with the C locale, standard output and error written to the
-- worker-owned logs. `completed(ok, term, code)` runs once, after the child
-- was reaped, with io.popen-close shaped results. Returns the child, or nil
-- and an error (nothing is reported then).
function process.start_job(argv, stdout_path, stderr_path, completed)
    library()
    local stdout, stderr = open_logs(stdout_path, stderr_path)
    if not stdout then return nil, stderr end
    local child, err = spawn(argv, { nil, stdout, stderr }, nil,
        function(code, signal) completed(exit_status(code, signal)) end)
    close_logs(stdout, stderr)
    if not child then
        uv.run("nowait") -- Release the handle of a failed spawn attempt.
        return nil, err
    end
    return child
end

-- Length-prefixed control records: a 4-byte big-endian length, then that
-- many bytes. The bound admits the record codec's own limit plus framing.
local RECORD_LIMIT = 256 * 1024 * 1024 + 64

function process.frame(payload)
    assert(#payload <= RECORD_LIMIT, "control record exceeds its bound")
    return string.pack(">s4", payload)
end

function process.new_frames()
    return setmetatable({ chunks = {}, size = 0 }, Frames)
end

function Frames:take(count)
    local joined = table.concat(self.chunks)
    local rest = joined:sub(count + 1)
    self.chunks = rest ~= "" and { rest } or {}
    self.size = #rest
    return joined:sub(1, count)
end

-- Append received bytes; returns the complete payloads, or nil and an error
-- for an oversized record.
function Frames:push(data)
    self.chunks[#self.chunks + 1] = data
    self.size = self.size + #data
    local payloads = {}
    while true do
        if not self.need then
            if self.size < 4 then break end
            local length = string.unpack(">I4", self:take(4))
            if length > RECORD_LIMIT then
                return nil, "control record of " .. length .. " bytes exceeds its bound"
            end
            self.need = length
        end
        if self.size < self.need then break end
        payloads[#payloads + 1] = self:take(self.need)
        self.need = nil
    end
    return payloads
end

-- True when end of file would cut a record short.
function Frames:partial()
    return self.need ~= nil or self.size > 0
end

-- Closed-data record codec: the compiler's bounded literal graph codec
-- (strings, booleans, numbers and plain tables; never functions, userdata or
-- Lua source), checked with the native SHA-256 when it is installed.
local function codec_options()
    local called, support = pcall(require, "titan")
    local digest = called and type(support) == "table" and support._sha256_binary
    return { sha256_binary = type(digest) == "function" and digest or nil }
end

function process.encode_record(record)
    return require("titan-compiler.graphcodec").encode(record, codec_options())
end

function process.decode_record(payload)
    local record, err =
        require("titan-compiler.graphcodec").decode(payload, codec_options())
    if record == nil then return nil, err end
    if type(record) ~= "table" then return nil, "control record is not a table" end
    return record
end

-- A build worker: `argv` spawned directly (never through a shell or a PATH
-- launcher) in `options.cwd` with the parent's environment. Standard output
-- and error are captured whole for deterministic replay, and descriptor 3 is
-- a private duplex pipe carrying length-prefixed control records. POSIX
-- descriptors in `options.inherit` follow as descriptors 4, 5, ... (the
-- build coordinator's output-tree locks). Handlers: `record(payload)` per
-- complete record, `failed(err)` on a read or framing failure (reading then
-- stops), `exited(code, signal)` once reaped, and `settled()` once the child
-- exited and every pipe reached end of file.
function process.start_worker(argv, options, handlers)
    library()
    local worker = setmetatable({
        stdout = {}, stderr = {}, frames = process.new_frames(), open = 0,
    }, Worker)
    local pipes = {}
    local names = { "stdin_pipe", "stdout_pipe", "stderr_pipe", "control" }
    for index, name in ipairs(names) do
        local pipe, err = uv.new_pipe(false)
        if not pipe then
            for _, created in ipairs(pipes) do created:close() end
            uv.run("nowait")
            return nil, err
        end
        pipes[index] = pipe
        worker[name] = pipe
    end
    local function check_settled()
        if worker.exited and worker.open == 0 and not worker.settled then
            worker.settled = true
            handlers.settled()
        end
    end
    local function finish_stream(pipe)
        if pipe:is_closing() then return end
        worker.open = worker.open - 1
        pipe:close()
        check_settled()
    end
    -- Standard input is an empty pipe whose writer closes at once, so the
    -- array has no hole before the inherited descriptors.
    local stdio = { worker.stdin_pipe, worker.stdout_pipe, worker.stderr_pipe,
        worker.control }
    for index, descriptor in ipairs(options.inherit or {}) do
        stdio[4 + index] = descriptor
    end
    local child, err = spawn(argv, stdio,
        { cwd = options.cwd, inherit_environment = true },
        function(code, signal)
            worker.exited, worker.code, worker.signal = true, code, signal
            handlers.exited(code, signal)
            check_settled()
        end)
    worker.stdin_pipe:close()
    if not child then
        for index = 2, #pipes do pipes[index]:close() end
        uv.run("nowait")
        return nil, err
    end
    worker.child = child
    local function capture(pipe, chunks)
        worker.open = worker.open + 1
        local started, read_err = pipe:read_start(function(stream_err, data)
            if data then
                chunks[#chunks + 1] = data
            else
                if stream_err then
                    chunks[#chunks + 1] = "\n(output capture failed: " ..
                        tostring(stream_err) .. ")\n"
                end
                finish_stream(pipe)
            end
        end)
        if not started then
            chunks[#chunks + 1] = "(output capture failed: " .. tostring(read_err) .. ")\n"
            finish_stream(pipe)
        end
    end
    capture(worker.stdout_pipe, worker.stdout)
    capture(worker.stderr_pipe, worker.stderr)
    worker.open = worker.open + 1
    local started, read_err = worker.control:read_start(function(stream_err, data)
        if worker.control:is_closing() then return end
        local failure
        if data then
            local payloads, frame_err = worker.frames:push(data)
            if not payloads then
                failure = frame_err
            else
                for _, payload in ipairs(payloads) do handlers.record(payload) end
            end
        elseif stream_err then
            failure = "control channel read failed: " .. tostring(stream_err)
        elseif worker.frames:partial() then
            failure = "control channel ended inside a record"
        end
        if failure then handlers.failed(failure) end
        if failure or not data then finish_stream(worker.control) end
    end)
    if not started then
        handlers.failed("cannot read the control channel: " .. tostring(read_err))
        finish_stream(worker.control)
    end
    return worker
end

-- Queue one record for the worker. Returns true, or nil and an error.
function Worker:send(payload)
    if self.control:is_closing() then return nil, "the control channel is closed" end
    local called, ok, err = pcall(self.control.write, self.control,
        process.frame(payload))
    if not called then return nil, tostring(ok) end
    if not ok then return nil, tostring(err) end
    return true
end

-- Signal a live worker (POSIX signal number or luv signal name; Windows
-- terminates it). A child that already exited is not an error.
function Worker:kill(signal)
    if self.exited then return true end
    local called, ok, err = pcall(self.child.handle.kill, self.child.handle, signal)
    if not called then return nil, tostring(ok) end
    return ok ~= nil or nil, err
end

-- The worker's end of its control pipe (descriptor 3 by default).
function process.open_control(descriptor)
    library()
    local pipe, err = uv.new_pipe(false)
    if not pipe then return nil, err end
    local opened
    opened, err = pipe:open(descriptor or 3)
    if not opened then
        pipe:close()
        uv.run("nowait")
        return nil, "cannot open the build control channel: " .. tostring(err)
    end
    local control = setmetatable({
        pipe = pipe, frames = process.new_frames(), queue = {},
    }, Control)
    local started, read_err = pipe:read_start(function(stream_err, data)
        if data then
            local payloads, frame_err = control.frames:push(data)
            if not payloads then
                control.error = frame_err
            else
                for _, payload in ipairs(payloads) do
                    control.queue[#control.queue + 1] = payload
                end
            end
        elseif stream_err then
            control.error = "control channel read failed: " .. tostring(stream_err)
        else
            control.ended = true
        end
        if control.error or control.ended then pipe:read_stop() end
    end)
    if not started then
        pipe:close()
        uv.run("nowait")
        return nil, "cannot read the build control channel: " .. tostring(read_err)
    end
    return control
end

-- Write one record and wait until the bytes were handed to the kernel.
function Control:send(payload)
    local done, write_err = false, nil
    local called, ok, err = pcall(self.pipe.write, self.pipe, process.frame(payload),
        function(callback_err)
            done, write_err = true, callback_err
        end)
    if not called then return nil, tostring(ok) end
    if not ok then return nil, tostring(err) end
    while not done do uv.run("once") end
    if write_err then return nil, "control channel write failed: " .. tostring(write_err) end
    return true
end

-- Wait for the next complete record; nil and an error at end of file or on
-- a framing failure.
function Control:receive()
    while #self.queue == 0 do
        if self.error then return nil, self.error end
        if self.ended then
            return nil, "the build coordinator closed the control channel"
        end
        uv.run("once")
    end
    return table.remove(self.queue, 1)
end

function Control:close()
    if not self.pipe:is_closing() then self.pipe:close() end
    uv.run("nowait")
end

return process

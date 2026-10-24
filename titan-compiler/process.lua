-- Windows compiler process transport. Importing it does not load native code.
local process = {}
local Process = {}
Process.__index = Process
local Batch = {}
Batch.__index = Batch
local uv

local function library()
    uv = uv or require "luv"
    return uv
end

local function environment(overrides)
    local values, result = {}, {}
    for name, value in pairs(uv.os_environ()) do
        values[name:upper()] = name .. "=" .. value
    end
    for name, value in pairs(overrides or {}) do
        values[name:upper()] = value ~= false and name .. "=" .. value or nil
    end
    values.LANG, values.LC_ALL = "LANG=C", "LC_ALL=C"
    for _, value in pairs(values) do result[#result + 1] = value end
    return result
end

local function spawn(argv, stdio, options, completed)
    local child = setmetatable({}, Process)
    local arguments = {}
    for index = 2, #argv do arguments[#arguments + 1] = argv[index] end
    local handle, err = uv.spawn(argv[1], {
        args = arguments, stdio = stdio,
        cwd = options and options.cwd,
        env = environment(options and options.env),
    }, function(code, signal)
        child.code, child.signal = code, signal
        child.handle:close(function() child.closed = true end)
        if completed then completed() end
    end)
    if not handle then return nil, err end
    child.handle = handle
    return child
end

function Process:wait()
    while not self.closed do uv.run("once") end
    if self.signal ~= 0 then return nil, "signal", self.signal end
    return self.code == 0 and true or nil, "exit", self.code
end
Process.close = Process.wait

function process.new_batch()
    library()
    return setmetatable({ children = {}, ready = {}, pending = 0 }, Batch)
end

-- Equal paths share one descriptor, so the child's merged output keeps its
-- write order (the C probe batch captures diagnostics this way).
function Batch:spawn(argv, stdout_path, stderr_path, completion_index)
    local stdout, err = uv.fs_open(stdout_path, "w", 420)
    if not stdout then return nil, err end
    local stderr = stdout
    if stderr_path ~= stdout_path then
        stderr, err = uv.fs_open(stderr_path, "w", 420)
        if not stderr then uv.fs_close(stdout); return nil, err end
    end
    local child
    child, err = spawn(argv, { nil, stdout, stderr }, nil, function()
        self.pending = self.pending - 1
        self.ready[#self.ready + 1] = completion_index
    end)
    uv.fs_close(stdout)
    if stderr ~= stdout then uv.fs_close(stderr) end
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

return process

-- One short-lived build worker of a titanc coordinator (titan-compiler.build).
-- The coordinator starts it with the exact Lua interpreter and module paths
-- it runs itself; descriptor 3 carries closed control records. The worker
-- compiles exactly the one planned module it is sent, routes every native
-- batch to the coordinator's job-slot ledger, reports one result record and
-- exits. It never publishes: the coordinator alone does that.
-- Implementation notes: doc/implementation/driver.md#build-worker-transport
local jobs = require "titan-compiler.jobs"
local process = require "titan-compiler.process"
local version = require "titan-compiler.version"

local build_worker = {}

local Session = {}
Session.__index = Session

-- Open the control channel and read the coordinator's compile request.
-- Returns the session (`session.request` is the request's payload), or nil
-- and an error.
function build_worker.connect(descriptor)
    local control, err = process.open_control(descriptor)
    if not control then return nil, err end
    local payload
    payload, err = control:receive()
    local record
    if payload then record, err = process.decode_record(payload) end
    if not record then
        control:close()
        return nil, "cannot read the build request: " .. tostring(err)
    end
    if record.kind ~= "compile" or record.protocol ~= version.BUILD_WORKER_PROTOCOL or
       type(record.request) ~= "table" then
        control:close()
        return nil, "incompatible build coordinator request (expected protocol " ..
            tostring(version.BUILD_WORKER_PROTOCOL) .. ")"
    end
    return setmetatable({
        control = control, request = record.request, batches = 0,
    }, Session)
end

-- The jobs.lua remote executor: one native batch, answered only after the
-- coordinator reaped every child it started and granted this frontend its
-- slot again. Transport failures are returned, never raised.
function Session:run_batch(batch)
    self.batches = self.batches + 1
    local id = self.batches
    local payload, err = process.encode_record({ kind = "native", id = id, jobs = batch })
    if not payload then return nil, "cannot encode a native batch: " .. tostring(err) end
    local sent
    sent, err = self.control:send(payload)
    local reply
    if sent then reply, err = self.control:receive() end
    if not reply and self.control.ended then
        -- The coordinator is gone; its ledger and these children are too.
        io.stderr:write("titanc build worker: the build coordinator exited\n")
        os.exit(3)
    end
    local record
    if reply then record, err = process.decode_record(reply) end
    if not record then return nil, tostring(err) end
    if record.kind ~= "native-result" or record.id ~= id or
       type(record.results) ~= "table" then
        return nil, "unexpected build coordinator reply"
    end
    return record.results, record.failure, record.cancelled
end

-- Send the single result record: { ok = true, result = data } or
-- { ok = false, diagnostics = { text, ... } }.
function Session:finish(outcome)
    local payload, err = process.encode_record({
        kind = "result", ok = outcome.ok == true,
        result = outcome.result, diagnostics = outcome.diagnostics,
    })
    if not payload then
        payload, err = process.encode_record({
            kind = "result", ok = false,
            diagnostics = { "cannot encode the build result: " .. tostring(err) },
        })
    end
    if not payload then return nil, err end
    local sent, send_err = self.control:send(payload)
    self.control:close()
    if not sent then return nil, send_err end
    return true
end

-- True once the coordinator closed its end of the control channel.
function Session:abandoned()
    process.library().run("nowait")
    return self.control.ended or self.control.error ~= nil
end

local function diagnostic_list(value)
    if type(value) == "table" then
        local list = {}
        for index, item in ipairs(value) do list[index] = tostring(item) end
        if #list > 0 then return list end
    end
    return { tostring(value) }
end

-- The resolver I/O of a worker: the ordinary synchronous strategy whose
-- cooperative yield also notices a coordinator that went away. Nobody can
-- publish this worker's work any more, so it exits at once; the inherited
-- output-tree lock is released with it.
local function worker_io(session)
    local sync = require("titan-compiler.io").new_sync()
    local strategy = setmetatable({}, { __index = sync })
    function strategy.yield(_, ...)
        if session:abandoned() then
            io.stderr:write("titanc build worker: the build coordinator exited\n")
            os.exit(3)
        end
        return sync:yield(...)
    end
    return strategy
end

local function compile(session)
    local driver = require "titan-compiler.driver"
    local request = session.request
    local context, context_err =
        driver.new_worker_context(request.configuration, worker_io(session))
    if not context then
        return { ok = false, diagnostics = diagnostic_list(context_err) }
    end
    local called, result, compile_err = xpcall(
        driver.compile_planned_module, function(err)
            if type(err) == "string" then return err end
            return debug.traceback(tostring(err), 2)
        end, context, request.module, request.options)
    local closed, close_err = driver.close_resolver_context(context)
    if not called then
        io.stderr:write(tostring(result), "\n")
        return { ok = false, diagnostics = diagnostic_list(result) }
    elseif not result then
        return { ok = false, diagnostics = diagnostic_list(compile_err) }
    elseif not closed then
        return { ok = false, diagnostics = {
            "failed to clean C probe service: " .. tostring(close_err) } }
    elseif type(result.diagnostics) == "table" and #result.diagnostics > 0 then
        return { ok = false, diagnostics = diagnostic_list(result.diagnostics) }
    end
    return { ok = true, result = result }
end

function build_worker.main()
    local session, err = build_worker.connect()
    if not session then
        io.stderr:write("titanc build worker: ", tostring(err), "\n")
        os.exit(2)
    end
    jobs.use_remote(session)
    local called, outcome = xpcall(compile, debug.traceback, session)
    if not called then
        outcome = { ok = false, diagnostics = {
            "internal error in the build worker for module '" ..
                tostring(session.request.module) .. "': " .. tostring(outcome) } }
    end
    local sent, send_err = session:finish(outcome)
    if not sent then
        io.stderr:write("titanc build worker: cannot report the result: ",
            tostring(send_err), "\n")
        os.exit(2)
    end
    os.exit(0)
end

return build_worker

-- Run by jobserver_spec.lua under a real parent Make, and by its native jobs.
local mode, repository, workspace, kind = arg[1], arg[2], arg[3], arg[4]
package.path = repository .. "/?.lua;" .. repository .. "/?/init.lua;" .. package.path
local jobs = require "titan-compiler.jobs"
local process = require "titan-compiler.process"
local uv = process.library()
local interpreter = assert(uv.exepath())
local fixture = repository .. "/spec/fixtures/parallel_compilation/jobserver_process.lua"
local bootstrap = string.format("package.path=%q; package.cpath=%q;", package.path, package.cpath)

local function identity(stat)
    return tostring(stat.dev) .. ":" .. tostring(stat.ino)
end

local function inspect(expected_read, expected_write)
    local auth = assert(jobs.make_policy(os.getenv("MAKEFLAGS")).auth)
    assert(auth.kind == kind, "unexpected jobserver transport")
    if kind == "pipe" then
        local read_stat, write_stat = assert(uv.fs_fstat(auth.read)), assert(uv.fs_fstat(auth.write))
        assert(read_stat.type == "fifo" and write_stat.type == "fifo", "jobserver descriptors are not pipes")
        assert(identity(read_stat) == expected_read, "jobserver read pipe changed")
        assert(identity(write_stat) == expected_write, "jobserver write pipe changed")
        local token = assert(uv.fs_read(auth.read, 1, -1))
        assert(#token == 1, "jobserver token missing")
        assert(uv.fs_write(auth.write, token, -1) == 1)
    elseif kind == "fifo" then
        assert(auth.path == expected_read, "jobserver FIFO path changed")
        assert(assert(uv.fs_stat(auth.path)).type == "fifo")
    end
end

local function command(child_mode, expected_read, expected_write, leased)
    return { interpreter, "-E", "-e", bootstrap, fixture, child_mode, repository,
        workspace, kind, expected_read, expected_write, leased and "leased" or "unleased" }
end

if mode == "child" then
    inspect(arg[5], arg[6])
    if arg[7] == "leased" then
        for index = 1, 2 do
            local actual = assert(uv.fs_fstat(2 + index))
            local expected = assert(uv.fs_stat(workspace .. "/lease-" .. index))
            assert(actual.type == "file" and identity(actual) == identity(expected),
                "native job lost its output lock")
        end
    end
    io.write("jobserver child completed\n")
elseif mode == "worker" then
    local control = assert(process.open_control(3, 4))
    local request = assert(process.decode_record(assert(control:receive())))
    inspect(request.read, request.write)
    local result = process.capture(command("child", request.read, request.write, true),
        { inherit = { 5, 6 }, inherit_environment = true })
    assert(result.ok, result.diagnostic)
    assert(control:send(assert(process.encode_record({ ok = true }))))
    control:close()
elseif mode == "parent" then
    local auth = assert(jobs.make_policy(os.getenv("MAKEFLAGS")).auth)
    assert(auth.kind == kind, "parent Make did not create the requested transport")
    local expected_read, expected_write
    if kind == "pipe" then
        local read_stat, write_stat = assert(uv.fs_fstat(auth.read)), assert(uv.fs_fstat(auth.write))
        assert(read_stat.type == "fifo" and write_stat.type == "fifo")
        expected_read, expected_write = identity(read_stat), identity(write_stat)
    else
        expected_read, expected_write = auth.path, "unused"
    end
    local locks, leases = {}, {}
    for index = 1, 2 do
        locks[index] = assert(require("titan")._output_lock_open(workspace .. "/lease-" .. index))
        leases[index] = locks[index]:descriptor()
    end
    local argv = command("child", expected_read, expected_write, true)
    assert(process.run(argv, { inherit = leases }))
    assert(process.run(argv, { inherit = leases, inherit_environment = true }))
    local captured = process.capture(argv, { inherit = leases })
    assert(captured.ok, captured.diagnostic)
    local inherited = process.capture(argv, { inherit = leases, inherit_environment = true })
    assert(inherited.ok, inherited.diagnostic)
    local stdout, stderr = workspace .. "/job.out", workspace .. "/job.err"
    local child = assert(process.start_job(argv, stdout, stderr, function() end, { inherit = leases }))
    local ok = child:wait()
    if not ok then
        local file = assert(io.open(stderr, "r"))
        error(file:read("a"))
    end
    local batch = assert(process.new_batch())
    assert(batch:spawn(command("child", expected_read, expected_write), stdout, stderr, 1))
    assert(batch:wait() == 1)
    assert(batch.children[1]:wait())
    assert(batch:close())
    local settled, response, worker_error, exit_code = false
    local worker = assert(process.start_worker(command("worker", expected_read, expected_write),
        { inherit = leases }, {
            record = function(payload) response = assert(process.decode_record(payload)) end,
            failed = function(message) worker_error = message end,
            exited = function(code) exit_code = code end,
            settled = function() settled = true end,
        }))
    assert(worker:send(assert(process.encode_record({ read = expected_read, write = expected_write }))))
    while not settled do uv.run("once") end
    assert(not worker_error, worker_error)
    assert(exit_code == 0, table.concat(worker.stderr))
    assert(response and response.ok, "worker control exchange failed")
    if kind == "pipe" then
        -- All auth options must be updated, without treating assignments as options.
        local flags = " --jobserver-fds=" .. auth.text .. " " .. os.getenv("MAKEFLAGS")
        local overridden = process.capture(argv, { inherit = leases, env = { MAKEFLAGS = flags } })
        assert(overridden.ok, overridden.diagnostic)
        for _, authorization in ipairs({
            "1000000,1000001", leases[1] .. "," .. leases[2], "-2,-2",
        }) do
            local unavailable = process.capture({ interpreter, "-E", "-e", bootstrap .. [[
local jobs = require "titan-compiler.jobs"
local auth = assert(jobs.make_policy(os.getenv("MAKEFLAGS")).auth)
assert(auth.kind == "pipe" and auth.read < 0 and auth.write < 0)
]], }, { inherit = leases, env = { MAKEFLAGS = "-j3 --jobserver-auth=" .. authorization } })
            assert(unavailable.ok, unavailable.diagnostic)
        end
    end
    for _, lock in ipairs(locks) do assert(lock:close()) end
    io.write("all native jobserver transports completed\n")
else
    error("unknown jobserver fixture mode")
end

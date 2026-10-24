-- GNU Make jobserver participation for generated-C batches: MAKEFLAGS
-- policy, the exact-byte token ledger, real parent-Make FIFO and pipe
-- pools, conservation on failure and cancellation, and overlap counted from
-- the real compiler processes (spec/fixtures/parallel_compilation).
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local installed_prefix = require "spec.support.installed_prefix"
local jobs = require "titan-compiler.jobs"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"
local types = require "titan-compiler.types"

local ROOT = lfs.currentdir()
local FIXTURE = ROOT .. "/spec/fixtures/parallel_compilation"
local WRAPPER = FIXTURE .. "/counting_cc.sh"
local TIMEOUT = ROOT .. "/spec/support/run_with_timeout.sh"
local LEAVES = { "one", "two", "three", "four", "five", "six", "seven", "eight" }
local PREFIX = installed_prefix.active()
local LUA = PREFIX .. "/bin/lua"
local LINUX = not platform.windows and
    io.popen("uname -s"):read("l") == "Linux"

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

local function shell(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = assert(pipe:read("a"))
    local ok, why, code = pipe:close()
    return ok, output, why, code
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

local function count_lines(path)
    if not exists(path) then return 0 end
    local count = 0
    for _ in read_file(path):gmatch("[^\n]+") do count = count + 1 end
    return count
end

local function sorted_bytes(text)
    local bytes = { text:byte(1, -1) }
    table.sort(bytes)
    return bytes
end

-- An ambient Make pool must not leak into these fixtures.
local CLEAN_MAKE_ENV = "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS"

local MAKE_VERSION
local function make_version()
    if MAKE_VERSION == nil then
        local ok, output = shell("make --version")
        local major, minor
        if ok then major, minor = output:match("GNU Make (%d+)%.(%d+)") end
        MAKE_VERSION = major and tonumber(major) * 100 + tonumber(minor) or false
    end
    return MAKE_VERSION or nil
end

-- A parent pool titanc can share: GNU Make 4.4's FIFO, or a Linux pipe.
local function shared_pool_available()
    local version = make_version()
    return version and (version >= 404 or LINUX)
end

describe("make jobserver policy", function()
    it("parses the last FIFO, pipe, and legacy authorization", function()
        assert.same({ kind = "fifo", path = "/tmp/GMfifo1", text = "fifo:/tmp/GMfifo1" },
            jobs.make_policy("s -j4 --jobserver-auth=fifo:/tmp/GMfifo1").auth)
        assert.same({ kind = "pipe", read = 4, write = 5, text = "4,5" },
            jobs.make_policy("ks -j3 --jobserver-auth=4,5").auth)
        assert.same({ kind = "pipe", read = 3, write = 4, text = "3,4" },
            jobs.make_policy(" --jobserver-fds=3,4 -j").auth)
        -- GNU Make 4.4 appends an unusable pair for recipes without '+'.
        assert.same({ kind = "pipe", read = -2, write = -2, text = "-2,-2" },
            jobs.make_policy("s -j4 --jobserver-auth=4,5 --jobserver-auth=-2,-2").auth)
        assert.same({ kind = "invalid", text = "gmake_semaphore_7" },
            jobs.make_policy("-j4 --jobserver-auth=gmake_semaphore_7").auth)
        assert.same({ kind = "fifo", path = "/tmp/a b", text = "fifo:/tmp/a b" },
            jobs.make_policy([[-j2 --jobserver-auth=fifo:/tmp/a\ b]]).auth)
    end)

    it("treats only an explicit -j1 without a server as serial", function()
        assert.is_true(jobs.make_policy("s -j1").serial)
        assert.is_false(jobs.make_policy("s -j").serial)
        assert.is_false(jobs.make_policy("s").serial)
        assert.is_false(jobs.make_policy(nil).serial)
        assert.is_false(jobs.make_policy("-j1 --jobserver-auth=3,4").serial)
        -- Command-line variable assignments follow a standalone "--".
        local policy = jobs.make_policy("s -- FLAGS=-j1 X=--jobserver-auth=3,4")
        assert.is_false(policy.serial)
        assert.is_nil(policy.auth)
    end)
end)

describe("jobserver slots", function()
    if platform.windows then
        it("use only the local cap on Windows", function()
            local slots = assert(jobs.open_slots(4,
                { makeflags = "-j2 --jobserver-auth=3,4" }))
            assert.equal(4, slots.limit)
            assert.is_false(slots.shared)
            assert(slots:close())
        end)
        return
    end

    local support = require "titan"
    local workspace, fifo, holder
    local previous_stderr

    -- A FIFO pool holding exact, unusual token bytes. The holder keeps the
    -- channel open so unread tokens survive between clients.
    local function pool(bytes)
        fifo = workspace .. "/pool"
        assert(shell("mkfifo -m 600 " .. quote(fifo)))
        holder = assert(io.open(fifo, "r+"))
        assert(holder:setvbuf("no"))
        assert(holder:write(bytes))
    end

    -- Count (and return) every token currently available, nonblocking.
    local function available()
        local probe = assert(support._jobserver_open("fifo", fifo))
        local count = 0
        while assert(probe:acquire() ~= nil) and probe:held() > count do
            count = count + 1
        end
        assert(probe:close())
        return count
    end

    local function drain(count)
        return holder:read(count)
    end

    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        previous_stderr = io.stderr
    end)

    after_each(function()
        io.stderr = previous_stderr
        if holder then holder:close() end
        holder = nil
        remove_tree(workspace)
    end)

    it("borrow one exact byte per extra active job and return them", function()
        pool("\0\255")
        local slots = assert(jobs.open_slots(4,
            { makeflags = "-j3 --jobserver-auth=fifo:" .. fifo }))
        assert.is_true(slots.shared)
        assert.equal(4, slots.limit)
        assert.is_true(slots:acquire_nowait())   -- implicit slot
        assert.is_true(slots:acquire_nowait())   -- borrowed
        assert.is_true(slots:acquire_nowait())   -- borrowed
        assert.is_false(slots:acquire_nowait())  -- pool exhausted
        assert.equal(0, available())
        assert(slots:release())
        assert.equal(1, available())
        assert(slots:release())
        assert(slots:release())
        assert.equal(2, available())
        assert.is_true(slots:acquire_nowait())
        assert.is_true(slots:acquire_nowait())
        assert(slots:close())
        assert.equal(2, available())
        assert.same(sorted_bytes("\0\255"), sorted_bytes(drain(2)))
    end)

    it("stay within the local cap under a larger pool", function()
        pool("+++++++")
        local slots = assert(jobs.open_slots(2,
            { makeflags = "-j8 --jobserver-auth=fifo:" .. fifo }))
        assert.is_true(slots:acquire_nowait())
        assert.is_true(slots:acquire_nowait())
        assert.is_false(slots:acquire_nowait())
        assert.equal(6, available())
        assert(slots:close())
        assert.equal(7, available())
    end)

    it("return borrowed bytes when a ledger is collected", function()
        pool("ab")
        do
            local client = assert(support._jobserver_open("fifo", fifo))
            assert.is_true(client:acquire())
            assert.is_true(client:acquire())
            assert.is_false(client:acquire())
        end
        collectgarbage()
        collectgarbage()
        assert.equal(2, available())
    end)

    it("fall back to one job once for an unusable server", function()
        local warnings = {}
        io.stderr = { write = function(_, ...)
            for index = 1, select("#", ...) do
                warnings[#warnings + 1] = select(index, ...)
            end
            return true
        end }
        package.loaded["titan-compiler.jobs"] = nil
        local fresh = require "titan-compiler.jobs"
        package.loaded["titan-compiler.jobs"] = jobs
        for _, makeflags in ipairs({
            "s -j4 --jobserver-auth=4,5 --jobserver-auth=-2,-2",
            "-j4 --jobserver-auth=fifo:" .. workspace .. "/missing",
            "-j4 --jobserver-auth=900,901",
            "-j4 --jobserver-auth=gmake_semaphore_7",
        }) do
            local slots = assert(fresh.open_slots(4, { makeflags = makeflags }))
            assert.equal(1, slots.limit, makeflags)
            assert.is_false(slots.shared)
            assert(slots:close())
        end
        local text = table.concat(warnings)
        local _, count = text:gsub("titanc: warning: the parent make jobserver", "")
        assert.equal(1, count, text)
        assert.truthy(text:find("(-2,-2) is unusable", 1, true), text)
    end)

    it("use one job silently for make -j1 and the local cap without Make", function()
        local slots = assert(jobs.open_slots(4, { makeflags = "s -j1" }))
        assert.equal(1, slots.limit)
        assert(slots:close())
        slots = assert(jobs.open_slots(4, { makeflags = "s -j" }))
        assert.equal(4, slots.limit)
        assert.is_false(slots.shared)
        assert(slots:close())
        slots = assert(jobs.open_slots(3, { makeflags = false }))
        assert.equal(3, slots.limit)
        assert(slots:close())
    end)

    it("reject a second concurrent signal guard and restore on close", function()
        local slots = assert(jobs.open_slots(2, { makeflags = false }))
        local second, err = jobs.open_slots(2, { makeflags = false })
        assert.is_nil(second)
        assert.truthy(tostring(err):find("already active", 1, true), err)
        assert(slots:close())
        assert(slots:close())
        local third = assert(jobs.open_slots(2, { makeflags = false }))
        assert(third:close())
    end)
end)

describe("native SHA-256", function()
    local support = require "titan"
    local sha256 = require "titan-compiler.sha256"

    local function hex(bytes)
        return (("%02x"):rep(#bytes):format(bytes:byte(1, -1)))
    end

    it("matches the standard vectors and the pure-Lua digest", function()
        local vectors = {
            [""] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ["abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"] =
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            [string.rep("a", 1000000)] =
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        }
        for message, expected in pairs(vectors) do
            local digest = support._sha256_binary(message)
            assert.equal(32, #digest)
            assert.equal(expected, hex(digest))
            assert.equal(sha256.binary(message), digest)
        end
    end)

    it("handles embedded NULs, every block boundary, and large input", function()
        for length = 0, 200 do
            local message = string.rep("\0\1\255x", 64):sub(1, length)
            assert.equal(sha256.binary(message), support._sha256_binary(message), length)
        end
        local large = string.rep("titan\0", 400000)
        assert.equal(sha256.binary(large), support._sha256_binary(large))
        assert.equal(sha256.hex(large), sha256.hex_via(support._sha256_binary, large))
    end)

    it("accepts only strings", function()
        assert.has_error(function() support._sha256_binary(42) end)
        assert.has_error(function() support._sha256_binary(nil) end)
    end)
end)

describe("generated-C batches under a parent Make", function()
    if platform.windows then
        it("are POSIX-only", function() pending("Windows uses the luv batch") end)
        return
    end

    local workspace, state
    local holder

    local function launcher()
        local path = workspace .. "/titanc.sh"
        write_file(path, table.concat({
            "#!/bin/sh",
            "exec env -u TITAN_JOBS CC=" .. quote(WRAPPER) ..
                " TITAN_EXTRA_CPPFLAGS= TITAN_EXTRA_CFLAGS= TITAN_EXTRA_LDFLAGS=" ..
                " TITAN_PARALLEL_TEST_STATE=" .. quote(state) ..
                ' TITAN_PARALLEL_TEST_DELAY="${DELAY:-0.5}"' ..
                ' TITAN_PARALLEL_TEST_EXPECTED="${EXPECTED:-1}"' ..
                ' TITAN_PARALLEL_TEST_FAIL="${FAIL:-}"' ..
                " TITAN_ROCKS_ROOT=" .. quote(PREFIX) ..
                " TITAN_RUNTIME_PREBUILT=1 " .. quote(LUA) .. " -e " ..
                quote("package.path = " .. string.format("%q",
                    ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") ..
                    " .. package.path") ..
                " " .. quote(ROOT .. "/titanc") .. ' "$@"',
            "",
        }, "\n"))
        assert(shell("chmod +x " .. quote(path)))
    end

    -- One source tree per recipe; the counting compiler's state is shared,
    -- so `maximum` is the real overlap across every recipe of the pool.
    local function tree(name, leaves)
        assert(lfs.mkdir(workspace .. "/" .. name))
        assert(lfs.mkdir(workspace .. "/" .. name .. "/batch"))
        local modules = {}
        for _, leaf in ipairs(leaves) do
            write_file(workspace .. "/" .. name .. "/batch/" .. leaf .. ".titan",
                read_file(FIXTURE .. "/src/batch/" .. leaf .. ".titan"))
            modules[#modules + 1] = "batch." .. leaf
        end
        return "-c -o out-" .. name .. " --tree " .. name .. " " ..
            table.concat(modules, " ")
    end

    local function recipe(target, arguments, plus)
        return target .. ":\n\t" .. (plus == false and "" or "+") ..
            "./titanc.sh " .. arguments .. "\n"
    end

    local function makefile(text)
        write_file(workspace .. "/Makefile", text)
    end

    local function run_make(arguments, environment)
        return shell(CLEAN_MAKE_ENV .. " " .. (environment or "") .. " " ..
            quote(TIMEOUT) .. " 90 make -C " .. quote(workspace) .. " " ..
            arguments)
    end

    local function maximum()
        return tonumber(read_file(state .. "/maximum"))
    end

    local function compiled(name, leaves)
        for _, leaf in ipairs(leaves) do
            if not exists(workspace .. "/out-" .. name .. "/batch/" .. leaf .. ".o") then
                return false, leaf
            end
        end
        return true
    end

    -- A pool owned by the test with exact token bytes; titanc runs as the
    -- one recipe that holds the implicit slot.
    local function pool(bytes)
        local fifo = workspace .. "/pool"
        assert(shell("mkfifo -m 600 " .. quote(fifo)))
        holder = assert(io.open(fifo, "r+"))
        assert(holder:setvbuf("no"))
        assert(holder:write(bytes))
        return fifo
    end

    local function available(fifo)
        local probe = assert(require("titan")._jobserver_open("fifo", fifo))
        local count = 0
        while assert(probe:acquire() ~= nil) and probe:held() > count do
            count = count + 1
        end
        assert(probe:close())
        return count
    end

    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        state = workspace .. "/state"
        assert(lfs.mkdir(state))
        launcher()
    end)

    after_each(function()
        if holder then holder:close() end
        holder = nil
        remove_tree(workspace)
    end)

    it("fill a FIFO pool smaller than the local cap", function()
        if not make_version() or make_version() < 404 then
            pending("GNU Make 4.4 FIFO jobserver unavailable")
            return
        end
        makefile("all: one\n" .. recipe("one", tree("a", LEAVES)))
        local ok, output = run_make("-j3", "EXPECTED=3")
        assert.truthy(ok, output)
        assert.equal(3, maximum(), output)
        assert.equal(8, count_lines(state .. "/commands"))
        assert.truthy(compiled("a", LEAVES))
    end)

    it("bound a larger pool by the local --jobs cap", function()
        if not shared_pool_available() then pending("no shareable Make pool") return end
        makefile("all: one\n" .. recipe("one", "--jobs 2 " .. tree("a", LEAVES)))
        local ok, output = run_make("-j8", "EXPECTED=2")
        assert.truthy(ok, output)
        assert.equal(2, maximum(), output)
    end)

    it("reopen a pipe pool privately or fall back to one job", function()
        local version = make_version()
        if not version then pending("GNU Make unavailable") return end
        makefile("all: one\n" .. recipe("one", tree("a", LEAVES)))
        local style = version >= 404 and "--jobserver-style=pipe " or ""
        if LINUX then
            local ok, output = run_make(style .. "-j3", "EXPECTED=3")
            assert.truthy(ok, output)
            assert.equal(3, maximum(), output)
            assert.falsy(output:find("jobserver", 1, true), output)
        else
            -- Stock macOS Make 3.81 cannot be reopened privately.
            local ok, output = run_make(style .. "-j3", "EXPECTED=1")
            assert.truthy(ok, output)
            assert.equal(1, maximum(), output)
            assert.truthy(output:find("titanc: warning: the parent make jobserver", 1, true), output)
        end
    end)

    it("warn once and use one job when a pipe recipe lacks '+'", function()
        local version = make_version()
        if not version or version < 404 then pending("GNU Make 4.4 unavailable") return end
        makefile("all: one\n" .. recipe("one", tree("a", LEAVES), false))
        local ok, output = run_make("--jobserver-style=pipe -j4", "EXPECTED=1")
        assert.truthy(ok, output)
        assert.equal(1, maximum(), output)
        local _, warnings = output:gsub("titanc: warning: the parent make jobserver", "")
        assert.equal(1, warnings, output)
    end)

    it("stay serial under make -j1", function()
        makefile("all: one\n" .. recipe("one", tree("a", { "one", "two", "three" })))
        local ok, output = run_make("-j1", "EXPECTED=1 DELAY=0.2")
        assert.truthy(ok, output)
        assert.equal(1, maximum(), output)
    end)

    it("share make -j2 between two recipes without deadlock", function()
        local first = { "one", "two", "three", "four" }
        local second = { "five", "six", "seven", "eight" }
        makefile("all: first second\n" .. recipe("first", tree("a", first)) ..
            recipe("second", tree("b", second)))
        local ok, output = run_make("-j2", "EXPECTED=2 DELAY=0.3")
        assert.truthy(ok, output)
        assert.equal(2, maximum(), output)
        assert.equal(8, count_lines(state .. "/commands"))
        assert.truthy(compiled("a", first))
        assert.truthy(compiled("b", second))
    end)

    it("conserve exact token bytes across success and compile failure", function()
        local fifo = pool("\0\255\n")
        local arguments = tree("a", LEAVES)
        for _, failure in ipairs({ "", "three" }) do
            remove_tree(state)
            assert(lfs.mkdir(state))
            local ok, output = shell(CLEAN_MAKE_ENV .. " MAKEFLAGS=" ..
                quote("-j4 --jobserver-auth=fifo:" .. fifo) ..
                " EXPECTED=4 FAIL=" .. failure .. " " .. quote(TIMEOUT) ..
                " 90 sh -c " .. quote("cd " .. quote(workspace) ..
                    " && ./titanc.sh " .. arguments))
            if failure == "" then assert.truthy(ok, output)
            else
                assert.falsy(ok, output)
                assert.truthy(output:find("parallel compiler sentinel: three", 1, true), output)
            end
            assert.equal(4, maximum(), output)
            assert.equal(8, count_lines(state .. "/commands"), output)
            assert.equal(3, available(fifo), output)
        end
        assert.same(sorted_bytes("\0\255\n"), sorted_bytes(holder:read(3)))
    end)

    it("reopen inherited pipe descriptors without changing them", function()
        if not LINUX then pending("Linux /proc reopen") return end
        local fifo = pool("xyz")
        local script = table.concat({
            "cd " .. quote(workspace),
            "exec 3<>" .. quote(fifo) .. " 4>" .. quote(fifo),
            "MAKEFLAGS='-j4 --jobserver-auth=3,4' EXPECTED=4 ./titanc.sh " ..
                tree("a", LEAVES) .. " || exit $?",
            "awk '/^flags:/ { print \"read-flags=\" $2 }' /proc/$$/fdinfo/3",
            "awk '/^flags:/ { print \"write-flags=\" $2 }' /proc/$$/fdinfo/4",
        }, "\n")
        local ok, output = shell(CLEAN_MAKE_ENV .. " " .. quote(TIMEOUT) ..
            " 90 sh -c " .. quote(script))
        assert.truthy(ok, output)
        assert.equal(4, maximum(), output)
        for _, name in ipairs({ "read", "write" }) do
            local flags = assert(output:match(name .. "%-flags=(%d+)"), output)
            -- O_NONBLOCK (04000 octal) must stay clear on the shared descriptions.
            assert.equal(0, tonumber(flags, 8) & tonumber("4000", 8), output)
        end
        assert.equal(3, available(fifo), output)
    end)

    local function cancel(signal)
        local fifo = pool("+-=")
        local arguments = tree("a", LEAVES)
        local pid_file = workspace .. "/titanc.pid"
        local script = "cd " .. quote(workspace) .. " && { DELAY=2 EXPECTED=4 " ..
            "MAKEFLAGS=" .. quote("-j4 --jobserver-auth=fifo:" .. fifo) ..
            " ./titanc.sh " .. arguments .. " & echo $! > " .. quote(pid_file) ..
            "; wait $!; echo \"status=$?\"; }"
        local pipe = assert(io.popen(CLEAN_MAKE_ENV .. " sh -c " ..
            quote(script) .. " 2>&1", "r"))
        for _ = 1, 600 do
            if count_lines(state .. "/commands") >= 4 and exists(pid_file) then break end
            os.execute("sleep 0.05")
        end
        assert.equal(4, count_lines(state .. "/commands"))
        local pid = assert(tonumber(read_file(pid_file)))
        assert(os.execute("kill -" .. signal .. " " .. pid))
        local output = pipe:read("a")
        pipe:close()
        -- Running compilers drain; nothing else starts or is published.
        assert.equal("0\n", read_file(state .. "/active"), output)
        assert.equal(4, count_lines(state .. "/commands"), output)
        for _, leaf in ipairs(LEAVES) do
            assert.falsy(exists(workspace .. "/out-a/batch/" .. leaf .. ".o"), leaf)
        end
        -- Batch-owned staging (compile logs, the completion FIFO, object
        -- temporaries) uses `.tmp.` siblings; none may survive the drain.
        for _, directory in ipairs({ "/out-a", "/out-a/batch" }) do
            for entry in lfs.dir(workspace .. directory) do
                assert.falsy(entry:find(".tmp.", 1, true), directory .. "/" .. entry)
            end
        end
        assert.equal(3, available(fifo), output)
        return output
    end

    it("drain, return tokens, and re-raise SIGTERM", function()
        local output = cancel("TERM")
        assert.truthy(output:find("status=143", 1, true), output)
    end)

    it("drain, return tokens, and re-raise SIGINT through Lua", function()
        local output = cancel("INT")
        assert.truthy(output:find("interrupted!", 1, true), output)
        assert.truthy(output:find("status=1\n", 1, true), output)
    end)
end)

describe("in-process batches under a parent pool", function()
    if platform.windows then return end

    local workspace, state, source_root, holder
    local previous_cc, previous_popen, previous_getenv

    local function checked_requests(leaves)
        types.registry = {}
        local requests = {}
        for _, leaf in ipairs(leaves) do
            local modname = "batch." .. leaf
            local filename = source_root .. "/batch/" .. leaf .. ".titan"
            local source = read_file(filename)
            local ast, parse_err = parser.parse(filename, source)
            assert.truthy(ast, parse_err)
            local _, errors = checker.check(modname, ast, source, filename)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            requests[#requests + 1] = {
                modname = modname,
                mod = { ast = ast, filename = filename },
                static_deps = {},
            }
        end
        return requests
    end

    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        state = workspace .. "/state"
        source_root = workspace .. "/src"
        assert(lfs.mkdir(state))
        assert(lfs.mkdir(source_root))
        assert(lfs.mkdir(source_root .. "/batch"))
        for _, leaf in ipairs({ "one", "two", "three", "four" }) do
            write_file(source_root .. "/batch/" .. leaf .. ".titan",
                read_file(FIXTURE .. "/src/batch/" .. leaf .. ".titan"))
        end
        local fifo = workspace .. "/pool"
        assert(shell("mkfifo -m 600 " .. quote(fifo)))
        holder = assert(io.open(fifo, "r+"))
        assert(holder:setvbuf("no"))
        assert(holder:write("\1\2"))
        previous_cc, previous_popen, previous_getenv = driver.CC, io.popen, platform.getenv
        platform.getenv = function(name)
            if name == "MAKEFLAGS" then return "-j3 --jobserver-auth=fifo:" .. fifo end
            return previous_getenv(name)
        end
        driver.CC = "env TITAN_PARALLEL_TEST_STATE=" .. quote(state) ..
            " TITAN_PARALLEL_TEST_DELAY=0.3 TITAN_PARALLEL_TEST_EXPECTED=3 " ..
            quote(WRAPPER)
    end)

    after_each(function()
        driver.CC, io.popen, platform.getenv = previous_cc, previous_popen, previous_getenv
        types.registry = {}
        if holder then holder:close() end
        holder = nil
        remove_tree(workspace)
    end)

    it("return the token of a failed launch and keep the batch going", function()
        local launches = 0
        io.popen = function(command, mode)
            launches = launches + 1
            if launches == 2 then return nil, "injected launch failure" end
            return previous_popen(command, mode)
        end
        local results = driver.compile_modules(checked_requests(
            { "one", "two", "three", "four" }), 4, false)
        io.popen = previous_popen
        local failed = 0
        for _, result in ipairs(results) do
            if not result.ok then
                failed = failed + 1
                assert.truthy(tostring(result.err):find("injected launch failure", 1, true))
            end
        end
        assert.equal(1, failed)
        assert.equal(3, count_lines(state .. "/commands"))
        assert.equal(3, tonumber(read_file(state .. "/maximum")))
        assert.same(sorted_bytes("\1\2"), sorted_bytes(holder:read(2)))
    end)
end)

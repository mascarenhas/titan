local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"
local LATE_FS_CASES =
    require "spec.support.uv_late_fs_callback_cases"
local REPO = async_stdlib.repo
local LPEGLABEL_ARCHIVE =
    REPO .. "/lpeglabel-build/libtitan-lpeglabel.a"
local LPEGLABEL_CPPFLAGS = "-I" .. REPO .. "/vendor/lpeglabel"

local fs_only_setting = os.getenv("TITAN_TEST_UV_LATE_FS_ONLY")
assert(fs_only_setting == nil or fs_only_setting == "" or
       fs_only_setting == "1",
    "TITAN_TEST_UV_LATE_FS_ONLY must be unset or 1")
local FS_ONLY = fs_only_setting == "1"
local describe_dns = FS_ONLY and function() end or describe

local LATE_DNS_CASES = [==[
-- Runs only against the generated delayed-DNS callback uv variant.
local lua = foreign import "lua.h"
local net = import "net"
local timer = import "timer"
local uv = import "uv"
local async = import "async"

local dns_result_published = false

function dns_result_was_published(): boolean
  return dns_result_published
end

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function read_all(connection: net.Connection): string
  local result = ""
  for chunk in connection:read do
    result = result .. chunk
  end
  return result
end

local function listen_available(host: string, first_port: integer,
                                backlog: integer): (net.Server, integer)
  local port = first_port
  local attempts = 0
  while attempts < 1024 do
    do
      local server = net.listen(host, port, backlog)
      return server, port
    catch
      local failure = error as async.Error
      if failure.name ~= "EADDRINUSE" then raise error end
    end
    attempts = attempts + 1
    port = port + 1
    if port > 60999 then port = 20000 end
  end
  raise "could not find an available loopback port"
end

local function expect_cancelled(task: async.Task, reason: string)
  local caught = false
  do
    task:join()
  catch
    local cancelled = error as async.Cancelled
    check(cancelled.reason == reason, "cancellation reason changed")
    caught = true
  end
  check(caught and task:status() == "cancelled",
        "Task did not finish cancelled")
end

function schedule_late_success(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 4)
    local peer = async.run(function (): value
      local connection = server:accept()
      check(read_all(connection) == "late-success",
            "late-success payload changed")
      connection:close()
      return "late-peer-ok"
    end)

    uv.__test_reset_dns_release_count()
    uv.__test_delay_next_dns_callback(35)
    local observed = async.run(function (): value
      while not uv.__test_dns_callback_is_delayed() do timer.yield() end
      return "delayed-observed"
    end)

    local connection = net.connect("127.0.0.1", port)
    check(observed:join() == "delayed-observed",
          "successful DNS callback was not delayed")
    connection:write("late-success")
    connection:shutdown()
    connection:close()
    check(peer:join() == "late-peer-ok", "late peer did not complete")
    server:close()
    check(uv.__test_dns_delivery_count() == 1,
          "successful DNS result was not delivered exactly once")
    check(uv.__test_dns_release_count() == 1,
          "successful DNS result was not released exactly once")
    return "late-success-ok"
  end)
end

function schedule_late_cancellation(port: integer): async.Task
  dns_result_published = false
  uv.__test_reset_dns_release_count()
  uv.__test_delay_next_dns_callback(50)

  local target = async.run(function (): value
    local connection = net.connect("127.0.0.1", port)
    dns_result_published = true
    connection:close()
    return "late-result-must-not-win"
  end)
  local canceller = async.run(function (): value
    while not uv.__test_dns_callback_is_delayed() do timer.yield() end
    target:cancel("late-dns-cancel")
    return nil
  end)

  return async.run(function (): value
    canceller:join()
    expect_cancelled(target, "late-dns-cancel")
    -- Keep the Runtime alive until the held physical result is delivered.
    timer.sleep(70)
    check(not dns_result_published,
          "late DNS result resumed a cancelled Task")
    check(uv.__test_dns_delivery_count() == 1,
          "cancelled held result was not delivered exactly once")
    check(uv.__test_dns_release_count() == 1,
          "cancelled held result was not released exactly once")
    return "late-cancellation-ok"
  end)
end

function schedule_shutdown_with_held_result(port: integer): async.Task
  dns_result_published = false
  uv.__test_reset_dns_release_count()
  uv.__test_delay_next_dns_callback(90)

  local target = async.run(function (): value
    local connection = net.connect("127.0.0.1", port)
    dns_result_published = true
    connection:close()
    return "shutdown-held-result-must-not-win"
  end)
  local canceller = async.run(function (): value
    while not uv.__test_dns_callback_is_delayed() do timer.yield() end
    target:cancel("shutdown-held-dns")
    return nil
  end)

  return async.run(function (): value
    canceller:join()
    expect_cancelled(target, "shutdown-held-dns")
    check(not dns_result_published,
          "held DNS result resumed before Runtime shutdown")
    -- Return with the delayed-delivery owner still active. maybe_finish_session
    -- enters Runtime shutdown; only the variant's one DNS owner is shielded.
    return "shutdown-held-ok"
  end)
end

function schedule_copy_failure(port: integer): async.Task
  uv.__test_reset_dns_release_count()
  uv.__test_delay_next_dns_callback(20)
  uv.__test_raise_during_next_dns_copy()
  return async.run(function (): value
    local connection = net.connect("127.0.0.1", port)
    connection:close()
    raise "injected DNS copy failure unexpectedly returned"
    return nil
  end)
end

function schedule_followup_round_trip(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    local peer = async.run(function (): value
      local connection = server:accept()
      check(read_all(connection) == "followup",
            "follow-up payload changed")
      connection:close()
      return "followup-peer-ok"
    end)
    uv.__test_reset_dns_release_count()
    local connection = net.connect("127.0.0.1", port)
    connection:write("followup")
    connection:shutdown()
    connection:close()
    check(peer:join() == "followup-peer-ok",
          "follow-up peer did not complete")
    server:close()
    check(uv.__test_dns_release_count() == 1,
          "follow-up DNS result was not released exactly once")
    return "followup-round-trip-ok"
  end)
end

function schedule_rooted_retry_gc(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 4)
    local peer = async.run(function (): value
      local connection = server:accept()
      check(read_all(connection) == "rooted-retry",
            "rooted retry payload changed")
      connection:close()
      return "rooted-retry-peer-ok"
    end)

    uv.__test_reset_dns_release_count()
    uv.__test_delay_next_dns_callback(45)
    uv.__test_prepend_invalid_dns_address()
    uv.__test_collect_after_next_dns_address_root()
    uv.__test_collect_across_next_dns_retry()

    -- Age Runtime/Task/operation while the borrowed addrinfo chain is held.
    -- Logical delivery then installs a young AddressList through the old
    -- operation and immediately forces both a generational step and full GC.
    local ager = async.run(function (): value
      while not uv.__test_dns_callback_is_delayed() do timer.yield() end
      lua.lua_gc(L, lua.LUA_GCGEN)
      lua.lua_gc(L, lua.LUA_GCCOLLECT)
      return "aged"
    end)

    local connection = net.connect("127.0.0.1", port)
    check(ager:join() == "aged", "DNS operation was not aged")
    check(uv.__test_dns_root_gc_count() == 1,
          "owned AddressList GC checkpoint did not run")
    check(uv.__test_dns_invalid_sync_failures() == 1,
          "leading zeroed address did not fail synchronously")
    check(uv.__test_dns_retry_after_close_count() == 1,
          "valid address retry began before failed handle close")
    check(uv.__test_dns_retry_gc_count() == 1,
          "close-before-retry GC checkpoint did not run")
    check(uv.__test_dns_release_count() == 1,
          "GC/retry DNS result was not released exactly once")

    connection:write("rooted-retry")
    connection:shutdown()
    connection:close()
    check(peer:join() == "rooted-retry-peer-ok",
          "rooted retry peer did not complete")
    server:close()
    return "rooted-retry-gc-ok"
  end)
end
]==]

-- Both timing hooks live in one exact, generated titan.uv provider. Each test
-- still executes in a fresh Lua process, so their mutable hook state remains
-- isolated while the expensive source/provider build is shared.
describe("uv delayed callback variants", function()
    local workspace
    local root
    local layout

    setup(function()
        local transformers
        if FS_ONLY then
            transformers = {
                "spec/support/make_delayed_fs_callback_variant.lua",
            }
        else
            transformers = {
                "spec/support/make_delayed_dns_callback_variant.lua",
                "spec/support/make_delayed_fs_callback_variant.lua",
            }
        end
        workspace, layout = async_stdlib.variant_workspace(transformers, {
            facades = false,
        })
        root = workspace .. "/data"
        assert.truthy(lfs.mkdir(root))
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source, {
                layout = layout,
            })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    local function port_prelude(scenario)
        return [==[
local cases = require "uv_late_dns_callback_cases"
local async = require "titan.async"
local uv = require "titan.uv"

local function port_seed(text)
    local hash = 0
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 30000
    end
    return 20000 + hash
end

local module_path = assert(package.searchpath(
    "uv_late_dns_callback_cases", package.cpath))
local first_port = port_seed(module_path .. ":]==] .. scenario .. [==[")

local function describe_failure(failure)
    local details = { tostring(failure) }
    for _, field in ipairs({ "operation", "name", "message", "subject" }) do
        local ok, value = pcall(function() return failure[field] end)
        if ok and value ~= nil then
            details[#details + 1] = field .. "=" .. tostring(value)
        end
    end
    return table.concat(details, ", ")
end

local function assert_loop()
    local ok, failure = pcall(async.loop)
    assert(ok, describe_failure(failure))
end
]==]
    end

    describe_dns("DNS cases", function()
        setup(function()
            -- Net now uses the complete string API, whose regex surface uses
            -- the complete PEG API. The sanitizer's FS-only mode skips this
            -- describe and therefore avoids this exact dependency closure.
            assert.truthy(lfs.attributes(LPEGLABEL_ARCHIVE, "mode"),
                "run make lpeglabel before delayed-DNS callback specs")
            for _, name in ipairs({
                "peg", "native", "combinators",
                "relabel", "relabel_parser",
            }) do
                async_stdlib.write_source(
                    workspace, "titan.peg." .. name,
                    async_stdlib.read(
                        "titan/peg/" .. name .. ".titan"))
            end
            async_stdlib.prepare_gc(workspace, layout)
            async_stdlib.compile(workspace, "titan.peg", {
                layout = layout,
                cppflags = LPEGLABEL_CPPFLAGS,
                extra_objects = { LPEGLABEL_ARCHIVE },
            })
            async_stdlib.register_exact_provider(layout, "titan.peg")

            for _, name in ipairs({
                "string", "bytes", "format", "pack",
                "regex_api", "regex_compile", "regex_parser",
            }) do
                async_stdlib.write_source(
                    workspace, "titan.string." .. name,
                    async_stdlib.read(
                        "titan/string/" .. name .. ".titan"))
            end
            async_stdlib.compile(workspace, "titan.string", {
                layout = layout,
                cppflags = "",
            })
            async_stdlib.register_exact_provider(
                layout, "titan.string")

            -- These convenience facades are needed only by the DNS cases.
            for _, modname in ipairs({ "titan.async", "titan.timer" }) do
                async_stdlib.compile(workspace, modname, {
                    layout = layout,
                    cppflags = "",
                })
                async_stdlib.register_exact_provider(layout, modname)
            end

            -- Build the public net facade only after the transformed exact uv
            -- provider exists, so it cannot fall back to the installed container.
            async_stdlib.write_source(workspace, "titan.net",
                async_stdlib.read(async_stdlib.repo .. "/titan/net.titan"))
            async_stdlib.compile(workspace, "titan.net", {
                layout = layout,
                cppflags = "",
            })
            async_stdlib.register_exact_provider(layout, "titan.net")

            async_stdlib.write_source(workspace, "uv_late_dns_callback_cases",
                LATE_DNS_CASES)
            async_stdlib.compile(workspace, "uv_late_dns_callback_cases", {
                layout = layout,
            })
        end)

        it("formats every decimal port boundary in the six-byte array", function()
            run([==[
            local uv = require "titan.uv"
            for _, expected in ipairs({
                { 0, "0" },
                { 9, "9" },
                { 10, "10" },
                { 65535, "65535" },
            }) do
                local text, terminator =
                    uv.__test_format_dns_port(expected[1])
                assert(text == expected[2], text)
                assert(terminator == 0, terminator)
            end
            ]==])
        end)

        it("delivers and releases a held successful result once", function()
            run(port_prelude("late-success") .. [==[
local task = cases.schedule_late_success(first_port)
assert_loop()
assert(task:join() == "late-success-ok")
]==])
        end)

        it("lets cancellation win without a stale resume", function()
            run(port_prelude("late-cancel") .. [==[
local task = cases.schedule_late_cancellation(first_port)
assert_loop()
assert(task:join() == "late-cancellation-ok")
]==])
        end)

        it("cleanup-shields a held result through Runtime shutdown", function()
            run(port_prelude("shutdown-held") .. [==[
local task = cases.schedule_shutdown_with_held_result(first_port)
assert_loop()
assert(task:join() == "shutdown-held-ok")
assert(uv.__test_dns_delivery_count() == 1)
assert(uv.__test_dns_release_count() == 1)
assert(not cases.dns_result_was_published())

local next_session = async.run(function()
    return "shutdown-followup-ok"
end)
assert_loop()
assert(next_session:join() == "shutdown-followup-ok")
]==])
        end)

        it("releases once after copy longjmp, drains, and reuses Runtime",
        function()
            run(port_prelude("copy-longjmp") .. [==[
local failed = cases.schedule_copy_failure(first_port)
local ok, failure = pcall(async.loop)
assert(not ok)
assert(tostring(failure):find(
    "injected delayed-DNS address copy failure", 1, true), tostring(failure))
assert(uv.__test_dns_delivery_count() == 1)
assert(uv.__test_dns_release_count() == 1)

local followup = cases.schedule_followup_round_trip(first_port + 1)
assert_loop()
assert(followup:join() == "followup-round-trip-ok")
]==])
        end)

        it("roots addresses across full/generational GC and failed retry",
        function()
            run(port_prelude("rooted-retry-gc") .. [==[
local task = cases.schedule_rooted_retry_gc(first_port)
assert_loop()
assert(task:join() == "rooted-retry-gc-ok")
]==])
        end)
    end)

    describe("filesystem cases", function()
        setup(function()
            async_stdlib.write_source(workspace, "uv_late_fs_callback_cases",
                LATE_FS_CASES)
            async_stdlib.compile(workspace, "uv_late_fs_callback_cases", {
                layout = layout,
            })
        end)

        it("roots a cross-generation Runtime/File/Task/buffer/error graph",
        function()
            run(string.format([==[
            local root = %q
            local cases = require "uv_late_fs_callback_cases"
            local task = cases.schedule_cross_generation_graph(root)
            cases.loop()
            assert(task:join() == "cross-generation-graph-ok")
            ]==], root))
        end)

        it("lets cancellation win over a delayed result", function()
            run(string.format([==[
            local root = %q
            local cases = require "uv_late_fs_callback_cases"
            local task = cases.schedule_late_fs_cancellation(root)
            cases.loop()
            assert(task:join() == "late-fs-cancellation-ok")
            ]==], root))
        end)

        it("disposes a delayed successful open after cancellation",
        function()
            run(string.format([==[
            local root = %q
            local cases = require "uv_late_fs_callback_cases"
            local path = root .. "/late-cancelled-open.dat"
            local task = cases.schedule_late_open_cancellation(path)
            cases.loop()
            assert(task:join() == "late-successful-open-cancellation-ok")
            assert(os.remove(path))

            -- A fresh Runtime session proves the cancelled-open File and request
            -- roots were fully retired without inspecting private Runtime lists.
            local next_session = cases.schedule_next_session()
            cases.loop()
            assert(next_session:join() == "next-session-ok")
            ]==], root))
        end)
    end)
end)

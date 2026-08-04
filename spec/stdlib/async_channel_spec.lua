local async_stdlib = require "spec.support.async_stdlib"

local CHANNEL_CASES = [==[
local async = import "async"
local timer = import "timer"
local gc = import "titan.gc"

interface ReaderCloserShape
  function read(): string?
  function read_until(delimiter: string, chop: boolean?): string?
  function close()
end

interface WriterCloserShape
  function write(data: string)
  function close()
end

local outcome = "not-run"
local discarded_finalized = false

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function wait_until_waiting(task: async.Task)
  while task:status():as_string() == "ready" do timer.yield() end
  check(task:status():as_string() == "waiting",
        "Task did not block on its channel")
end

local function cancelled_with(status: async.TaskStatus,
                              expected: string): boolean
  local cancelled, reason? = status:has_cancelled()
  if not cancelled then return false end
  local exact = reason as async.CancellationReason
  case exact
  when simple: message then return message == expected
  else return false
  end
end

function result(): string
  return outcome
end

function start_fifo(): async.Task
  outcome = "running"
  return async.run(function (): value
    local send, receive = async.channel(3)
    send("first")
    send(nil)
    send("third")
    check(receive() == "first", "channel lost its first item")
    check(receive() == nil, "channel did not carry nil")
    send("fourth")
    check(receive() == "third", "channel FIFO order changed")
    check(receive() == "fourth", "channel circular wrap changed")

    local zero_rejected = false
    do
      async.channel(0)
    catch
      zero_rejected = error is string
    end
    local negative_rejected = false
    do
      async.channel(-1)
    catch
      negative_rejected = error is string
    end
    check(zero_rejected and negative_rejected,
          "channel accepted a size below one")
    outcome = "fifo-ok"
    return nil
  end)
end

function start_handoffs(): async.Task
  outcome = "running"
  return async.run(function (): value
    -- The omitted size is one: the producer must block on its second send
    -- until this Task receives the buffered first item.
    local send, receive = async.channel()
    local producer_trace = ""
    local producer = async.run(function (): value
      producer_trace = producer_trace .. "send-first>"
      send("first")
      producer_trace = producer_trace .. "send-second>"
      send("second")
      producer_trace = producer_trace .. "sent"
      return nil
    end)
    wait_until_waiting(producer)
    check(producer_trace == "send-first>send-second>",
          "default channel did not block its full sender")
    check(receive() == "first", "default channel lost first handoff")
    check(receive() == "second", "default channel lost second handoff")
    check(async.join(producer):has_succeeded() and
          producer_trace == "send-first>send-second>sent",
          "blocked producer did not finish")

    -- Both sends request the same receiver wake before its zero timer fires.
    -- Task:resume must coalesce them while the receiver drains both items.
    local send_two, receive_two = async.channel(2)
    local received = ""
    local consumer = async.run(function (): value
      received = (receive_two() as string) .. ">" ..
                 (receive_two() as string)
      return nil
    end)
    wait_until_waiting(consumer)
    send_two("one")
    send_two("two")
    check(async.join(consumer):has_succeeded() and received == "one>two",
          "coalesced receiver wake lost a buffered item")

    outcome = "handoffs-ok"
    return nil
  end)
end

function start_single_waiters(): async.Task
  outcome = "running"
  return async.run(function (): value
    local send, receive = async.channel()
    local first_receiver = async.run(receive)
    wait_until_waiting(first_receiver)
    local receiver_rejected = false
    local second_receiver = async.run(function (): value
      do
        receive()
      catch
        receiver_rejected = error is string
      end
      return nil
    end)
    check(async.join(second_receiver):has_succeeded() and receiver_rejected,
          "channel accepted a second blocked receiver")
    send("received")
    receiver_rejected = false
    do
      receive()
    catch
      receiver_rejected = error is string
    end
    check(receiver_rejected,
          "channel let a receiver barge ahead of its blocked receiver")
    local receiver_status = async.join(first_receiver)
    local receiver_succeeded, receiver_value =
      receiver_status:has_succeeded()
    check(receiver_succeeded and receiver_value == "received",
          "first blocked receiver was disturbed")

    local send_full, receive_full = async.channel()
    send_full("stored")
    local first_sender = async.run(function (): value
      send_full("released")
      return nil
    end)
    wait_until_waiting(first_sender)
    local sender_rejected = false
    local second_sender = async.run(function (): value
      do
        send_full("rejected")
      catch
        sender_rejected = error is string
      end
      return nil
    end)
    check(async.join(second_sender):has_succeeded() and sender_rejected,
          "channel accepted a second blocked sender")
    check(receive_full() == "stored", "full channel lost stored item")
    sender_rejected = false
    do
      send_full("barging")
    catch
      sender_rejected = error is string
    end
    check(sender_rejected,
          "channel let a sender barge ahead of its blocked sender")
    check(receive_full() == "released", "first blocked sender was disturbed")
    check(async.join(first_sender):has_succeeded(),
          "first blocked sender did not finish")

    outcome = "single-waiters-ok"
    return nil
  end)
end

function start_cancelled_waiters(): async.Task
  outcome = "running"
  return async.run(function (): value
    local send, receive = async.channel()
    local cancelled_receiver = async.run(receive)
    wait_until_waiting(cancelled_receiver)
    cancelled_receiver:cancel(
      async.CancellationReason.simple("receiver cancelled"))
    check(cancelled_with(async.join(cancelled_receiver),
                         "receiver cancelled"),
          "blocked receiver cancellation changed")

    -- Cancellation must have removed the sole receive waiter, allowing a new
    -- Task to occupy that side of the channel.
    local replacement_receiver = async.run(receive)
    wait_until_waiting(replacement_receiver)
    send("replacement")
    local replacement_status = async.join(replacement_receiver)
    local replacement_succeeded, replacement =
      replacement_status:has_succeeded()
    check(replacement_succeeded and replacement == "replacement",
          "cancelled receiver left a stale waiter")

    local send_full, receive_full = async.channel()
    send_full("stored")
    local cancelled_sender = async.run(function (): value
      send_full("cancelled")
      return nil
    end)
    wait_until_waiting(cancelled_sender)
    cancelled_sender:cancel(
      async.CancellationReason.simple("sender cancelled"))
    check(cancelled_with(async.join(cancelled_sender), "sender cancelled"),
          "blocked sender cancellation changed")

    local replacement_sender = async.run(function (): value
      send_full("replacement")
      return nil
    end)
    wait_until_waiting(replacement_sender)
    check(receive_full() == "stored", "sender cleanup lost stored item")
    check(receive_full() == "replacement",
          "cancelled sender left a stale waiter")
    check(async.join(replacement_sender):has_succeeded(),
          "replacement sender did not finish")

    outcome = "cancelled-waiters-ok"
    return nil
  end)
end

function start_spurious_wakes(): async.Task
  outcome = "running"
  return async.run(function (): value
    local send, receive = async.channel()
    send("stored")
    local sender = async.run(function (): value
      send("released")
      return nil
    end)
    wait_until_waiting(sender)
    sender:resume()
    timer.sleep(2)
    check(sender:status():as_string() == "waiting",
          "direct resume let a sender overwrite a full channel")
    check(receive() == "stored", "spurious sender wake changed the buffer")
    check(receive() == "released", "rechecked sender did not enqueue")
    check(async.join(sender):has_succeeded(),
          "rechecked sender did not finish")

    local send_empty, receive_empty = async.channel()
    local receiver = async.run(receive_empty)
    wait_until_waiting(receiver)
    receiver:resume()
    timer.sleep(2)
    check(receiver:status():as_string() == "waiting",
          "direct resume let a receiver consume an empty channel")
    send_empty("delivered")
    local receiver_status = async.join(receiver)
    local receiver_succeeded, received = receiver_status:has_succeeded()
    check(receiver_succeeded and received == "delivered",
          "rechecked receiver did not consume the later item")

    outcome = "spurious-wakes-ok"
    return nil
  end)
end

local function close_buffered_finalizable(
    send: (value) -> (), close: () -> ())
  local payload: {string: value} = {}
  gc.finalizable(payload, function (_candidate: value)
    discarded_finalized = true
  end)
  send(payload)
  close()
end

function start_close(): async.Task
  outcome = "running"
  return async.run(function (): value
    local send, receive, close = async.channel(2)
    send("discarded")
    close()
    close()
    local send_error = ""
    do
      send("after close")
    catch
      send_error = error as string
    end
    local receive_error = ""
    do
      receive()
    catch
      receive_error = error as string
    end
    check(send_error == "channel is closed" and
          receive_error == "channel is closed",
          "closed channel accepted a direct operation")

    discarded_finalized = false
    local retain_send, _, retain_close = async.channel()
    close_buffered_finalizable(retain_send, retain_close)
    gc.collect()
    check(discarded_finalized,
          "close retained a buffered channel value")

    local _, blocked_receive, close_receive = async.channel()
    local receiver = async.run(function (): value
      do
        blocked_receive()
      catch
        return error
      end
      return "receiver did not raise"
    end)
    wait_until_waiting(receiver)
    close_receive()
    close_receive()
    local receiver_status = async.join(receiver)
    local receiver_succeeded, receiver_result =
      receiver_status:has_succeeded()
    check(receiver_succeeded and receiver_result == "channel is closed",
          "close did not wake its blocked receiver with an error")

    local blocked_send, drain, close_send = async.channel()
    blocked_send("stored")
    local sender = async.run(function (): value
      do
        blocked_send("blocked")
      catch
        return error
      end
      return "sender did not raise"
    end)
    wait_until_waiting(sender)
    close_send()
    close_send()
    local sender_status = async.join(sender)
    local sender_succeeded, sender_result = sender_status:has_succeeded()
    check(sender_succeeded and sender_result == "channel is closed",
          "close did not wake its blocked sender with an error")
    do
      drain()
    catch
      check(error == "channel is closed",
            "closed sender channel returned discarded data")
    end

    -- Cancellation remains authoritative if it races with the scheduled wake
    -- requested by close.
    local _, race_receive, race_close = async.channel()
    local racing = async.run(race_receive)
    wait_until_waiting(racing)
    race_close()
    racing:cancel(async.CancellationReason.simple("racing cancellation"))
    check(cancelled_with(async.join(racing), "racing cancellation"),
          "channel close displaced a competing Task cancellation")

    outcome = "close-ok"
    return nil
  end)
end


function start_reader_writer(): async.Task
  outcome = "running"
  return async.run(function (): value
    local zero_rejected = false
    do
      async.reader_writer_channel(0)
    catch
      zero_rejected = error is string
    end
    local negative_rejected = false
    do
      async.reader_writer_channel(-1)
    catch
      negative_rejected = error is string
    end
    check(zero_rejected and negative_rejected,
          "reader/writer adapter accepted a size below one")

    local invalid_reader, invalid_writer = async.reader_writer_channel()
    local delimiter_rejected = false
    do
      invalid_reader:read_until("", true)
    catch
      delimiter_rejected = error is string
    end
    check(delimiter_rejected,
          "ChannelReader accepted an empty delimiter")
    invalid_reader:close()
    invalid_writer:close()

    local concrete_reader, concrete_writer =
      async.reader_writer_channel()
    local reader: ReaderCloserShape = concrete_reader
    local writer: WriterCloserShape = concrete_writer
    local producer = async.run(function (): value
      writer:write("alpha<")
      writer:write(">beta")
      writer:write("::tail")
      return nil
    end)

    local first? = reader:read_until("<>", true)
    local second? = reader:read_until("::", false)
    local third? = reader:read()
    check(async.join(producer):has_succeeded(),
          "channel writer did not finish")
    check(first == "alpha" and second == "beta::" and third == "tail",
          "channel reader changed message-boundary parsing")
    reader:close()
    writer:close()
    check(reader:read() == nil,
          "closed ChannelReader returned data")

    local waiting_reader, closing_writer =
      async.reader_writer_channel()
    local close_result = "did not raise"
    local blocked = async.run(function (): value
      do
        waiting_reader:read()
      catch
        close_result = error as string
      end
      return nil
    end)
    wait_until_waiting(blocked)
    closing_writer:close()
    check(async.join(blocked):has_succeeded() and
          close_result == "channel is closed",
          "ChannelWriter close did not wake its blocked reader")
    waiting_reader:close()

    -- A delimiter suffix has already crossed the channel boundary and is
    -- reader-owned. Writer close preserves that excess; only the following
    -- receive observes the closed channel.
    local excess_reader, excess_writer =
      async.reader_writer_channel()
    excess_writer:write("head::tail")
    check(excess_reader:read_until("::", true) == "head",
          "ChannelReader did not split its buffered suffix")
    excess_writer:close()
    check(excess_reader:read() == "tail",
          "ChannelWriter close discarded reader-owned excess")
    local exhausted_error = ""
    do
      excess_reader:read()
    catch
      exhausted_error = error as string
    end
    check(exhausted_error == "channel is closed",
          "ChannelReader did not observe close after its excess")
    excess_reader:close()

    local closing_reader, blocked_writer =
      async.reader_writer_channel()
    blocked_writer:write("stored")
    local blocked_writer_error = "did not raise"
    local blocked_writer_task = async.run(function (): value
      do
        blocked_writer:write("blocked")
      catch
        blocked_writer_error = error as string
      end
      return nil
    end)
    wait_until_waiting(blocked_writer_task)
    closing_reader:close()
    check(async.join(blocked_writer_task):has_succeeded() and
          blocked_writer_error == "channel is closed",
          "ChannelReader close did not wake its blocked writer")

    local cancelled_reader, cancellation_writer =
      async.reader_writer_channel()
    local cancelled = async.run(function (): value
      return cancelled_reader:read()
    end)
    wait_until_waiting(cancelled)
    cancelled:cancel(
      async.CancellationReason.simple("adapter cancellation"))
    check(cancelled_with(async.join(cancelled), "adapter cancellation"),
          "ChannelReader changed blocked Task cancellation")
    local replacement = async.run(function (): value
      return cancelled_reader:read()
    end)
    wait_until_waiting(replacement)
    cancellation_writer:write("replacement")
    local replacement_status = async.join(replacement)
    local replacement_succeeded, replacement_value =
      replacement_status:has_succeeded()
    check(replacement_succeeded and replacement_value == "replacement",
          "cancelled ChannelReader left a stale receive waiter")
    cancelled_reader:close()

    outcome = "reader-writer-ok"
    return nil
  end)
end
]==]

describe("async channels", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("async-channel")
        async_stdlib.write_source(workspace, "async_channel_cases", CHANNEL_CASES)
        async_stdlib.compile(workspace, "async_channel_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run_case(start, expected)
        local ok, status, output = async_stdlib.run_lua_source(workspace, ([=[
            local async = require "titan.async"
            local cases = require "async_channel_cases"
            local task = cases.%s()
            async.loop()
            assert(task:status():as_string() == "succeeded",
                   task:status():as_string())
            assert(cases.result() == %q, cases.result())
        ]=]):format(start, expected))
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.falsy(output:find("uncaught error in async Task:", 1, true),
            output)
    end

    it("validates capacity and preserves nil-bearing FIFO order", function()
        run_case("start_fifo", "fifo-ok")
    end)

    it("blocks at capacity and coalesces repeated opposite-side wakes", function()
        run_case("start_handoffs", "handoffs-ok")
    end)

    it("allows only one blocked Task on each side", function()
        run_case("start_single_waiters", "single-waiters-ok")
    end)

    it("clears either waiter when its blocked Task is cancelled", function()
        run_case("start_cancelled_waiters", "cancelled-waiters-ok")
    end)

    it("rechecks buffer conditions after a direct Task wake", function()
        run_case("start_spurious_wakes", "spurious-wakes-ok")
    end)

    it("closes idempotently and wakes either blocked side with an error",
    function()
        run_case("start_close", "close-ok")
    end)

    it("adapts channels to string ReaderCloser and WriterCloser methods",
    function()
        run_case("start_reader_writer", "reader-writer-ok")
    end)
end)

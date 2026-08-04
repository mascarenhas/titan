local async_stdlib = require "spec.support.async_stdlib"

local COMBINATOR_CASES = [==[
local async = import "async"
local fs = import "fs"
local gc = import "titan.gc"
local str = import "string"
local timer = import "timer"

local outcome = "not-run"
local self_task: async.Task? = nil
local listener_cleanup_finalized = false

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function successful(result: value): async.Task
  return async.run(function (): value
    return result
  end)
end

local function sleeping(milliseconds: integer,
                        result: value): async.Task
  return async.run(function (): value
    timer.sleep(milliseconds)
    return result
  end)
end

local function cancelled(reason: string): async.Task
  local task = sleeping(60000, "unexpected cancellation return")
  task:cancel(async.CancellationReason.simple(reason))
  return task
end

local function failing(reason: value): async.Task
  return async.run(function (): value
    timer.yield()
    raise reason
    return nil
  end)
end

local function success_payload(status: async.TaskStatus): value
  local succeeded, result? = status:has_succeeded()
  check(succeeded, "expected succeeded Task status")
  return result
end

local function cancelled_payload(status: async.TaskStatus): value
  local cancelled_status, reason? = status:has_cancelled()
  check(cancelled_status, "expected cancelled Task status")
  local cancellation = reason as async.CancellationReason
  case cancellation
  when simple: text then return text
  when complex: payload then return payload
  else raise "invalid cancellation reason"
  end
end

local function wait_until_waiting(task: async.Task)
  while task:status():as_string() == "ready" do timer.yield() end
  check(task:status():as_string() == "waiting",
        "Task did not suspend")
end

local function any_two_tag(result: async.AnyTwoResult): string
  case result
  when first: payload then return "1:" .. (payload as string)
  when second: payload then return "2:" .. (payload as string)
  when none then return "none"
  else raise "invalid AnyTwoResult"
  end
end

local function any_three_tag(result: async.AnyThreeResult): string
  case result
  when first: payload then return "1:" .. (payload as string)
  when second: payload then return "2:" .. (payload as string)
  when third: payload then return "3:" .. (payload as string)
  when none then return "none"
  else raise "invalid AnyThreeResult"
  end
end

local function any_four_tag(result: async.AnyFourResult): string
  case result
  when first: payload then return "1:" .. (payload as string)
  when second: payload then return "2:" .. (payload as string)
  when third: payload then return "3:" .. (payload as string)
  when fourth: payload then return "4:" .. (payload as string)
  when none then return "none"
  else raise "invalid AnyFourResult"
  end
end

local function any_five_tag(result: async.AnyFiveResult): string
  case result
  when first: payload then return "1:" .. (payload as string)
  when second: payload then return "2:" .. (payload as string)
  when third: payload then return "3:" .. (payload as string)
  when fourth: payload then return "4:" .. (payload as string)
  when fifth: payload then return "5:" .. (payload as string)
  when none then return "none"
  else raise "invalid AnyFiveResult"
  end
end

local function race_two_tag(result: async.RaceTwoResult): string
  case result
  when first: status then return "1:" .. status:as_string()
  when second: status then return "2:" .. status:as_string()
  else raise "invalid RaceTwoResult"
  end
end

local function race_three_tag(result: async.RaceThreeResult): string
  case result
  when first: status then return "1:" .. status:as_string()
  when second: status then return "2:" .. status:as_string()
  when third: status then return "3:" .. status:as_string()
  else raise "invalid RaceThreeResult"
  end
end

local function race_four_tag(result: async.RaceFourResult): string
  case result
  when first: status then return "1:" .. status:as_string()
  when second: status then return "2:" .. status:as_string()
  when third: status then return "3:" .. status:as_string()
  when fourth: status then return "4:" .. status:as_string()
  else raise "invalid RaceFourResult"
  end
end

local function race_five_tag(result: async.RaceFiveResult): string
  case result
  when first: status then return "1:" .. status:as_string()
  when second: status then return "2:" .. status:as_string()
  when third: status then return "3:" .. status:as_string()
  when fourth: status then return "4:" .. status:as_string()
  when fifth: status then return "5:" .. status:as_string()
  else raise "invalid RaceFiveResult"
  end
end

local function caught_all_two(first: async.Task,
                              second: async.Task): string
  do
    async.all_two(first, second)
  catch
    local rejected = error as async.AllTwoError
    case rejected
    when first: status then
      cancelled_payload(status)
      return "1"
    when second: status then
      cancelled_payload(status)
      return "2"
    end
  end
  raise "all_two unexpectedly succeeded"
end

local function caught_all_three(first: async.Task, second: async.Task,
                                third: async.Task): string
  do
    async.all_three(first, second, third)
  catch
    local rejected = error as async.AllThreeError
    case rejected
    when first: status then
      cancelled_payload(status)
      return "1"
    when second: status then
      cancelled_payload(status)
      return "2"
    when third: status then
      cancelled_payload(status)
      return "3"
    end
  end
  raise "all_three unexpectedly succeeded"
end

local function caught_all_four(first: async.Task, second: async.Task,
                               third: async.Task,
                               fourth: async.Task): string
  do
    async.all_four(first, second, third, fourth)
  catch
    local rejected = error as async.AllFourError
    case rejected
    when first: status then
      cancelled_payload(status)
      return "1"
    when second: status then
      cancelled_payload(status)
      return "2"
    when third: status then
      cancelled_payload(status)
      return "3"
    when fourth: status then
      cancelled_payload(status)
      return "4"
    end
  end
  raise "all_four unexpectedly succeeded"
end

local function caught_all_five(first: async.Task, second: async.Task,
                               third: async.Task, fourth: async.Task,
                               fifth: async.Task): string
  do
    async.all_five(first, second, third, fourth, fifth)
  catch
    local rejected = error as async.AllFiveError
    case rejected
    when first: status then
      cancelled_payload(status)
      return "1"
    when second: status then
      cancelled_payload(status)
      return "2"
    when third: status then
      cancelled_payload(status)
      return "3"
    when fourth: status then
      cancelled_payload(status)
      return "4"
    when fifth: status then
      cancelled_payload(status)
      return "5"
    end
  end
  raise "all_five unexpectedly succeeded"
end

function result(): string
  return outcome
end

-- Most inputs have settled before these calls, systematically covering the
-- initial status scan and every positional result variant. The duplicated live
-- Task at the end covers listener registration and its left-to-right tie.
function start_any_variants(): async.Task
  outcome = "running"
  return async.run(function (): value
    local succeeded = successful("ok")
    local nil_succeeded = successful(nil)
    local first_cancelled = cancelled("first-cancel")
    local second_cancelled = cancelled("second-cancel")
    local logged_failure = failing("combinator-logged-failure")
    async.join_five(succeeded, nil_succeeded, first_cancelled,
                    second_cancelled, logged_failure)

    check(any_two_tag(async.any_two(succeeded, first_cancelled)) == "1:ok",
          "any_two first variant")
    check(any_two_tag(async.any_two(first_cancelled, succeeded)) == "2:ok",
          "any_two second variant")
    check(any_two_tag(async.any_two(first_cancelled,
                                    second_cancelled)) == "none",
          "any_two none variant")

    check(any_three_tag(async.any_three(
              succeeded, first_cancelled, second_cancelled)) == "1:ok",
          "any_three first variant")
    check(any_three_tag(async.any_three(
              first_cancelled, succeeded, second_cancelled)) == "2:ok",
          "any_three second variant")
    check(any_three_tag(async.any_three(
              first_cancelled, second_cancelled, succeeded)) == "3:ok",
          "any_three third variant")
    check(any_three_tag(async.any_three(
              first_cancelled, second_cancelled,
              first_cancelled)) == "none",
          "any_three none variant")

    check(any_four_tag(async.any_four(
              succeeded, first_cancelled, second_cancelled,
              first_cancelled)) == "1:ok", "any_four first variant")
    check(any_four_tag(async.any_four(
              first_cancelled, succeeded, second_cancelled,
              first_cancelled)) == "2:ok", "any_four second variant")
    check(any_four_tag(async.any_four(
              first_cancelled, second_cancelled, succeeded,
              first_cancelled)) == "3:ok", "any_four third variant")
    check(any_four_tag(async.any_four(
              first_cancelled, second_cancelled, first_cancelled,
              succeeded)) == "4:ok", "any_four fourth variant")
    check(any_four_tag(async.any_four(
              first_cancelled, second_cancelled, first_cancelled,
              second_cancelled)) == "none", "any_four none variant")

    check(any_five_tag(async.any_five(
              succeeded, first_cancelled, second_cancelled,
              first_cancelled, second_cancelled)) == "1:ok",
          "any_five first variant")
    check(any_five_tag(async.any_five(
              first_cancelled, succeeded, second_cancelled,
              first_cancelled, second_cancelled)) == "2:ok",
          "any_five second variant")
    check(any_five_tag(async.any_five(
              first_cancelled, second_cancelled, succeeded,
              first_cancelled, second_cancelled)) == "3:ok",
          "any_five third variant")
    check(any_five_tag(async.any_five(
              first_cancelled, second_cancelled, first_cancelled,
              succeeded, second_cancelled)) == "4:ok",
          "any_five fourth variant")
    check(any_five_tag(async.any_five(
              first_cancelled, second_cancelled, first_cancelled,
              second_cancelled, succeeded)) == "5:ok",
          "any_five fifth variant")
    check(any_five_tag(async.any_five(
              first_cancelled, second_cancelled, first_cancelled,
              second_cancelled, first_cancelled)) == "none",
          "any_five none variant")

    case async.any_two(nil_succeeded, first_cancelled)
    when first: payload then
      check(payload == nil, "any lost a nil success payload")
    else
      raise "nil success did not select any_two first"
    end
    case async.any_two(logged_failure, first_cancelled)
    when none then
    else
      raise "failed/cancelled any did not return none"
    end

    -- A duplicated terminal Task is an exact tie. Argument position, not Task
    -- identity, controls the result.
    check(any_two_tag(async.any_two(succeeded, succeeded)) == "1:ok",
          "any duplicate tie was not left-to-right")

    local live_duplicate = sleeping(2, "live-duplicate")
    check(any_two_tag(async.any_two(live_duplicate,
                                    live_duplicate)) == "1:live-duplicate",
          "live any duplicate tie was not left-to-right")
    local live_three = sleeping(2, "live-three")
    check(any_three_tag(async.any_three(live_three, live_three,
                                       live_three)) == "1:live-three",
          "live any_three duplicate tie was not left-to-right")
    local live_four = sleeping(2, "live-four")
    check(any_four_tag(async.any_four(live_four, live_four, live_four,
                                     live_four)) == "1:live-four",
          "live any_four duplicate tie was not left-to-right")
    local live_five = sleeping(2, "live-five")
    check(any_five_tag(async.any_five(live_five, live_five, live_five,
                                     live_five, live_five)) == "1:live-five",
          "live any_five duplicate tie was not left-to-right")

    -- Keep every operand live through the initial scan so the copied
    -- failed/cancelled listener arms, rather than only the scan arms, decide
    -- that no Task succeeded.
    local live_none_failure = failing("any-live-logged-failure")
    local live_none_second = cancelled("any-live-second")
    local live_none_third = cancelled("any-live-third")
    local live_none_fourth = cancelled("any-live-fourth")
    local live_none_fifth = cancelled("any-live-fifth")
    check(any_five_tag(async.any_five(
              live_none_failure, live_none_second, live_none_third,
              live_none_fourth, live_none_fifth)) == "none",
          "live any_five terminal listeners did not select none")
    outcome = "any-ok"
    return nil
  end)
end

function start_race_variants(): async.Task
  outcome = "running"
  return async.run(function (): value
    local succeeded = successful("winner")
    local pending = sleeping(60000, "late")
    async.join(succeeded)

    check(race_two_tag(async.race_two(succeeded, pending)) == "1:succeeded",
          "race_two first variant")
    local race_two_second =
      race_two_tag(async.race_two(pending, succeeded))
    check(race_two_second == "2:succeeded",
          "race_two second variant: " .. race_two_second)

    check(race_three_tag(async.race_three(
              succeeded, pending, pending)) == "1:succeeded",
          "race_three first variant")
    check(race_three_tag(async.race_three(
              pending, succeeded, pending)) == "2:succeeded",
          "race_three second variant")
    check(race_three_tag(async.race_three(
              pending, pending, succeeded)) == "3:succeeded",
          "race_three third variant")

    check(race_four_tag(async.race_four(
              succeeded, pending, pending, pending)) == "1:succeeded",
          "race_four first variant")
    check(race_four_tag(async.race_four(
              pending, succeeded, pending, pending)) == "2:succeeded",
          "race_four second variant")
    check(race_four_tag(async.race_four(
              pending, pending, succeeded, pending)) == "3:succeeded",
          "race_four third variant")
    check(race_four_tag(async.race_four(
              pending, pending, pending, succeeded)) == "4:succeeded",
          "race_four fourth variant")

    check(race_five_tag(async.race_five(
              succeeded, pending, pending, pending,
              pending)) == "1:succeeded", "race_five first variant")
    check(race_five_tag(async.race_five(
              pending, succeeded, pending, pending,
              pending)) == "2:succeeded", "race_five second variant")
    check(race_five_tag(async.race_five(
              pending, pending, succeeded, pending,
              pending)) == "3:succeeded", "race_five third variant")
    check(race_five_tag(async.race_five(
              pending, pending, pending, succeeded,
              pending)) == "4:succeeded", "race_five fourth variant")
    check(race_five_tag(async.race_five(
              pending, pending, pending, pending,
              succeeded)) == "5:succeeded", "race_five fifth variant")

    check(race_two_tag(async.race_two(succeeded,
                                      succeeded)) == "1:succeeded",
          "race duplicate tie was not left-to-right")

    local live_duplicate = sleeping(2, "race-live-duplicate")
    check(race_two_tag(async.race_two(live_duplicate,
                                      live_duplicate)) == "1:succeeded",
          "live race duplicate tie was not left-to-right")
    local live_three = sleeping(2, "race-live-three")
    check(race_three_tag(async.race_three(live_three, live_three,
                                         live_three)) == "1:succeeded",
          "live race_three duplicate tie was not left-to-right")
    local live_four = sleeping(2, "race-live-four")
    check(race_four_tag(async.race_four(live_four, live_four, live_four,
                                       live_four)) == "1:succeeded",
          "live race_four duplicate tie was not left-to-right")
    local live_five = sleeping(2, "race-live-five")
    check(race_five_tag(async.race_five(live_five, live_five, live_five,
                                       live_five,
                                       live_five)) == "1:succeeded",
          "live race_five duplicate tie was not left-to-right")

    local live_race_cancelled = cancelled("race-live-cancelled")
    check(race_five_tag(async.race_five(
              pending, pending, pending, pending,
              live_race_cancelled)) == "5:cancelled",
          "live race_five cancellation listener lost its position")
    check(not pending:status():has_finished(),
          "race cancelled an unfinished loser")

    local cancelled_task = cancelled("race-cancelled")
    local failed_task = failing("race-logged-failure")
    async.join_two(cancelled_task, failed_task)
    check(race_two_tag(async.race_two(cancelled_task,
                                      pending)) == "1:cancelled",
          "race did not return cancellation")
    check(race_two_tag(async.race_two(failed_task,
                                      pending)) == "1:failed",
          "race did not return failure")

    pending:cancel(async.CancellationReason.simple("race cleanup"))
    async.join(pending)
    outcome = "race-ok"
    return nil
  end)
end

function start_all_variants(): async.Task
  outcome = "running"
  return async.run(function (): value
    local first = sleeping(3, "one")
    local second = successful(nil)
    local third = successful("three")
    local fourth = successful("four")
    local fifth = successful("five")

    local one, two = async.all_two(first, second)
    check(one == "one" and two == nil, "all_two success values")
    local a, b, c = async.all_three(first, second, third)
    check(a == "one" and b == nil and c == "three",
          "all_three success values")
    local d, e, f, g = async.all_four(first, second, third, fourth)
    check(d == "one" and e == nil and f == "three" and g == "four",
          "all_four success values")
    local h, i, j, k, l =
      async.all_five(first, second, third, fourth, fifth)
    check(h == "one" and i == nil and j == "three" and
          k == "four" and l == "five", "all_five success values")

    local live_duplicate = sleeping(2, "all-live-duplicate")
    local duplicate_first, duplicate_second =
      async.all_two(live_duplicate, live_duplicate)
    check(duplicate_first == "all-live-duplicate" and
          duplicate_second == "all-live-duplicate",
          "live all duplicate lost a positional result")
    local live_three = sleeping(2, "all-live-three")
    local three_first, three_second, three_third =
      async.all_three(live_three, live_three, live_three)
    check(three_first == "all-live-three" and
          three_second == "all-live-three" and
          three_third == "all-live-three",
          "live all_three duplicate lost a positional result")
    local live_four = sleeping(2, "all-live-four")
    local four_first, four_second, four_third, four_fourth =
      async.all_four(live_four, live_four, live_four, live_four)
    check(four_first == "all-live-four" and
          four_second == "all-live-four" and
          four_third == "all-live-four" and
          four_fourth == "all-live-four",
          "live all_four duplicate lost a positional result")
    local live_five = sleeping(2, "all-live-five")
    local five_first, five_second, five_third, five_fourth, five_fifth =
      async.all_five(live_five, live_five, live_five, live_five, live_five)
    check(five_first == "all-live-five" and
          five_second == "all-live-five" and
          five_third == "all-live-five" and
          five_fourth == "all-live-five" and
          five_fifth == "all-live-five",
          "live all_five duplicate lost a positional result")

    local rejected = cancelled("all-cancelled")
    async.join(rejected)
    check(caught_all_two(rejected, first) == "1",
          "AllTwoError first variant")
    check(caught_all_two(first, rejected) == "2",
          "AllTwoError second variant")
    local tied_rejection = cancelled("all-tied-cancellation")
    async.join(tied_rejection)
    check(caught_all_two(rejected, tied_rejection) == "1",
          "all cancellation tie was not left-to-right")
    check(caught_all_three(rejected, first, first) == "1",
          "AllThreeError first variant")
    check(caught_all_three(first, rejected, first) == "2",
          "AllThreeError second variant")
    check(caught_all_three(first, first, rejected) == "3",
          "AllThreeError third variant")
    check(caught_all_four(rejected, first, first, first) == "1",
          "AllFourError first variant")
    check(caught_all_four(first, rejected, first, first) == "2",
          "AllFourError second variant")
    check(caught_all_four(first, first, rejected, first) == "3",
          "AllFourError third variant")
    check(caught_all_four(first, first, first, rejected) == "4",
          "AllFourError fourth variant")
    check(caught_all_five(rejected, first, first, first, first) == "1",
          "AllFiveError first variant")
    check(caught_all_five(first, rejected, first, first, first) == "2",
          "AllFiveError second variant")
    check(caught_all_five(first, first, rejected, first, first) == "3",
          "AllFiveError third variant")
    check(caught_all_five(first, first, first, rejected, first) == "4",
          "AllFiveError fourth variant")
    check(caught_all_five(first, first, first, first, rejected) == "5",
          "AllFiveError fifth variant")

    -- Exercise the live fifth listener rather than the initial status scan.
    local live_all_peer = sleeping(60000, "all live peer returned")
    local live_all_failure = failing("all-live-logged-failure")
    do
      async.all_five(live_all_peer, live_all_peer, live_all_peer,
                     live_all_peer, live_all_failure)
    catch
      local failure = error as async.AllFiveError
      case failure
      when fifth: status then
        local failed, details? = status:has_failed()
        check(failed and details ~= nil,
              "live all_five listener lost failed Task status")
      else
        raise "live all_five reported the wrong failed position"
      end
    end
    check(not live_all_peer:status():has_finished(),
          "live all_five cancelled an unfinished peer")
    live_all_peer:cancel(
      async.CancellationReason.simple("all live peer cleanup"))
    async.join(live_all_peer)

    local pending = sleeping(60000, "late")
    do
      async.all_two(rejected, pending)
    catch
      check(error is async.AllTwoError,
            "all raised a value of the wrong type")
    end
    check(not pending:status():has_finished(),
          "all cancelled an unfinished peer after rejection")
    pending:cancel(async.CancellationReason.simple("all cleanup"))
    async.join(pending)

    local failed_task = failing("all-logged-failure")
    async.join(failed_task)
    do
      async.all_two(first, failed_task)
    catch
      local failure = error as async.AllTwoError
      case failure
      when second: status then
        local failed, details? = status:has_failed()
        check(failed and details ~= nil,
              "all did not preserve failed Task status")
      else
        raise "all reported the wrong failed position"
      end
    end
    outcome = "all-ok"
    return nil
  end)
end

function start_join_and_status(path: string): async.Task
  outcome = "running"
  return async.run(function (): value
    local io_task = async.run(function (): value
      timer.sleep(2)
      fs.write_file(path, "joined-io")
      return fs.read_file(path)
    end)
    local nil_task = successful(nil)
    local cancelled_task = cancelled("join-cancelled")
    local failed_task = failing("join-logged-failure")
    local operation_task = async.run(function (): value
      timer.sleep(-1)
      return nil
    end)

    local io_status, nil_status, cancelled_status, failed_status,
          operation_status = async.join_five(
              io_task, nil_task, cancelled_task, failed_task,
              operation_task)
    check(success_payload(io_status) == "joined-io",
          "join lost I/O success payload")
    local nil_succeeded, nil_result? = nil_status:has_succeeded()
    check(nil_succeeded and nil_result == nil,
          "join lost nil success payload")
    check(cancelled_payload(cancelled_status) == "join-cancelled",
          "join lost cancellation reason")

    local default_cancelled = sleeping(60000, "default cancellation returned")
    default_cancelled:cancel(nil)
    check(cancelled_payload(async.join(default_cancelled)) == "cancelled",
          "cancel(nil) did not preserve the default simple reason")
    local marker: value = {}
    local complex_cancelled = sleeping(60000, "complex cancellation returned")
    complex_cancelled:cancel(async.CancellationReason.complex(marker))
    local complex_status = async.join(complex_cancelled)
    local has_complex, complex_reason? = complex_status:has_cancelled()
    check(has_complex and complex_reason ~= nil,
          "complex cancellation did not produce cancelled status")
    case complex_reason as async.CancellationReason
    when complex: payload then
      check(payload == marker, "complex cancellation payload changed")
    else
      raise "complex cancellation became a simple reason"
    end
    local failed, failure? = failed_status:has_failed()
    check(failed and failure ~= nil and
          (failure as async.Error).error == "join-logged-failure",
          "join lost arbitrary failure value")
    check((failure as async.Error).traceback ~= "",
          "Task failure has no traceback")
    check(str.find((failure as async.Error).traceback,
                   "stack traceback:") == nil and
          str.find((failure as async.Error).traceback,
                   "uncaught error in async Task:") == nil,
          "Error.traceback contains presentation headers")
    local operation_failed, operation_failure? =
      operation_status:has_failed()
    check(operation_failed and operation_failure ~= nil,
          "OperationError Task did not fail")
    check((operation_failure as async.Error).error is async.OperationError,
          "Error.error wrapped or replaced the OperationError")
    local operation_error =
      (operation_failure as async.Error).error as async.OperationError
    check(operation_error.operation == "timer.sleep" and
          operation_error.code < 0 and #operation_error.name > 0 and
          #operation_error.message > 0,
          "Error.error did not retain exact OperationError payload")

    -- Exercise every fixed join arity again with already-terminal Tasks.
    check(async.join(io_task):as_string() == "succeeded",
          "join single status")
    local j1, j2 = async.join_two(io_task, cancelled_task)
    check(j1:as_string() == "succeeded" and
          j2:as_string() == "cancelled", "join_two statuses")
    local j3, j4, j5 =
      async.join_three(io_task, cancelled_task, failed_task)
    check(j3:as_string() == "succeeded" and
          j4:as_string() == "cancelled" and
          j5:as_string() == "failed", "join_three statuses")
    local j6, j7, j8, j9 =
      async.join_four(io_task, nil_task, cancelled_task, failed_task)
    check(j6:as_string() == "succeeded" and
          j7:as_string() == "succeeded" and
          j8:as_string() == "cancelled" and
          j9:as_string() == "failed", "join_four statuses")
    local j10, j11, j12, j13, j14 = async.join_five(
      io_task, nil_task, cancelled_task, failed_task, operation_task)
    check(j10:has_finished() and j11:has_finished() and
          j12:has_finished() and j13:has_finished() and
          j14:has_finished(), "join_five returned active status")

    local live_duplicate = sleeping(2, "join-live-duplicate")
    local duplicate_first, duplicate_second =
      async.join_two(live_duplicate, live_duplicate)
    check(success_payload(duplicate_first) == "join-live-duplicate" and
          success_payload(duplicate_second) == "join-live-duplicate",
          "live join duplicate lost a positional status")
    local live_three = sleeping(2, "join-live-three")
    local three_first, three_second, three_third =
      async.join_three(live_three, live_three, live_three)
    check(success_payload(three_first) == "join-live-three" and
          success_payload(three_second) == "join-live-three" and
          success_payload(three_third) == "join-live-three",
          "live join_three duplicate lost a positional status")
    local live_four = sleeping(2, "join-live-four")
    local four_first, four_second, four_third, four_fourth =
      async.join_four(live_four, live_four, live_four, live_four)
    check(success_payload(four_first) == "join-live-four" and
          success_payload(four_second) == "join-live-four" and
          success_payload(four_third) == "join-live-four" and
          success_payload(four_fourth) == "join-live-four",
          "live join_four duplicate lost a positional status")
    local live_five = sleeping(2, "join-live-five")
    local five_first, five_second, five_third, five_fourth, five_fifth =
      async.join_five(live_five, live_five, live_five,
                      live_five, live_five)
    check(success_payload(five_first) == "join-live-five" and
          success_payload(five_second) == "join-live-five" and
          success_payload(five_third) == "join-live-five" and
          success_payload(five_fourth) == "join-live-five" and
          success_payload(five_fifth) == "join-live-five",
          "live join_five duplicate lost a positional status")
    outcome = "join-ok"
    return nil
  end)
end

-- Task identity, explicit suspension, synchronous resume scheduling, and
-- terminal notification are the primitives beneath every combinator.
function start_task_primitives(): async.Task
  outcome = "running"
  self_task = async.run(function (): value
    check(async.running() == (self_task as async.Task),
          "async.running did not return the current Task")

    local rejected = false
    do
      async.join(self_task as async.Task)
    catch
      rejected = error is string
    end
    check(rejected, "combinator accepted its running Task")

    local listener_order = ""
    local listener_status = ""
    local listener_ran_in_scheduler = false
    local removed_listener_ran = false
    local removed_listener = function (_status: async.TaskStatus)
      removed_listener_ran = true
      listener_order = listener_order .. "removed"
    end
    local target = async.run(function (): value
      timer.sleep(2)
      return "listener-result"
    end)
    local first_listener = function (status: async.TaskStatus)
      listener_order = listener_order .. "1"
      listener_status = status:as_string()
      do
        async.running()
      catch
        listener_ran_in_scheduler = true
      end
    end
    target:add_terminal_listener(first_listener)
    target:add_terminal_listener(removed_listener)
    target:add_terminal_listener(function (_status: async.TaskStatus)
      listener_order = listener_order .. "2"
      -- Terminal delivery uses a detached snapshot. Removing an already-run
      -- listener must not shift that snapshot and skip listener 3.
      target:remove_terminal_listener(first_listener)
      raise "swallowed-listener-error"
    end)
    target:add_terminal_listener(function (_status: async.TaskStatus)
      listener_order = listener_order .. "3"
    end)
    target:remove_terminal_listener(removed_listener)
    target:remove_terminal_listener(removed_listener)
    local target_status = async.join(target)
    check(success_payload(target_status) == "listener-result",
          "terminal listener target lost its result")
    check(listener_order == "123",
          "terminal listeners were not called sequentially")
    check(not removed_listener_ran,
          "removed terminal listener was invoked")
    check(listener_status == "succeeded",
          "terminal listener received the wrong status")
    check(listener_ran_in_scheduler,
          "terminal listener unexpectedly ran in a user Task")

    local late_listener_ran = false
    target:add_terminal_listener(function (_status: async.TaskStatus)
      late_listener_ran = true
    end)
    timer.yield()
    check(not late_listener_ran,
          "terminal Task retained or reran a listener")

    local suspended_task: async.Task? = nil
    local resumed_count = 0
    suspended_task = async.run(function (): value
      check(async.running() == (suspended_task as async.Task),
            "async.running changed inside suspended Task")
      async.suspend()
      resumed_count = resumed_count + 1
      return nil
    end)
    local target = suspended_task
    wait_until_waiting(target)
    target:resume()
    check(target:status():as_string() == "waiting" and
          resumed_count == 0,
          "Task:resume resumed a suspended Task synchronously")
    -- A second request before the timer fires must coalesce.
    target:resume()
    check(async.join(target):has_succeeded() and
          resumed_count == 1,
          "suspended Task did not receive exactly one scheduled wake")
    target:resume()
    timer.yield()
    check(resumed_count == 1,
          "Task:resume restarted a terminal Task")

    outcome = "primitives-ok"
    return nil
  end)
  return self_task as async.Task
end

-- Cancellation of a Task suspended inside a combinator wakes it through the
-- same explicit resume path. Unwinding removes its operand listener before a
-- later operand completion.
function start_cancelled_combinator(): async.Task
  outcome = "running"
  return async.run(function (): value
    local operand = sleeping(60000, "cancelled operand returned")
    local joining = async.run(function (): value
      async.join(operand)
      raise "cancelled combinator resumed user code"
      return nil
    end)
    wait_until_waiting(joining)
    joining:cancel(async.CancellationReason.simple("cancelled combinator"))
    check(joining:status():as_string() == "waiting" and
          not joining:status():has_finished(),
          "cancel published an intermediate TaskStatus")
    check(cancelled_payload(async.join(joining)) == "cancelled combinator",
          "suspended combinator cancellation reason changed")

    operand:cancel(async.CancellationReason.simple("operand cleanup"))
    check(cancelled_payload(async.join(operand)) == "operand cleanup",
          "late operand completion disturbed terminal combinator")
    outcome = "cancelled-combinator-ok"
    return nil
  end)
end

-- Identity, rather than an intermediate public cancellation state, rejects a
-- current Task after it requests its own cancellation.
function start_cancelled_self_rejection(): async.Task
  outcome = "running"
  local candidate: async.Task? = nil
  candidate = async.run(function (): value
    timer.yield()
    local current = candidate as async.Task
    current:cancel(async.CancellationReason.simple("self-cancelled"))
    check(current:status():as_string() == "running",
          "self-cancellation published an intermediate TaskStatus")
    local rejected = false
    do
      async.join(current)
    catch
      rejected = error is string
    end
    check(rejected, "combinator accepted its current Task")
    outcome = "cancelled-self-rejected"
    return nil
  end)
  return candidate as async.Task
end

local function cancel_join_with_finalizable(operand: async.Task)
  local sentinel: {string: value} = {}
  gc.finalizable(sentinel, function (_candidate: value)
    listener_cleanup_finalized = true
  end)
  local joining = async.run(function (): value
    async.join(operand)
    return nil
  end)
  wait_until_waiting(joining)
  joining:cancel(async.CancellationReason.complex(sentinel))
  local status = async.join(joining)
  check(status:has_cancelled(),
        "listener-retention probe did not cancel its combinator")
end

-- The operand remains alive while a finalizable value reachable only through
-- the cancelled combinator is collected. This proves defer removed the
-- operand listener instead of merely making its callback inert.
function start_listener_cleanup(): async.Task
  outcome = "running"
  return async.run(function (): value
    listener_cleanup_finalized = false
    local operand = sleeping(60000, "listener cleanup operand returned")
    cancel_join_with_finalizable(operand)
    gc.collect()
    check(listener_cleanup_finalized,
          "cancelled combinator remained retained by its operand listener")
    operand:cancel(async.CancellationReason.simple("operand cleanup"))
    async.join(operand)
    outcome = "listener-cleanup-ok"
    return nil
  end)
end
]==]

describe("async combinators", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("async-combinators")
        async_stdlib.write_source(
            workspace, "async_combinator_cases", COMBINATOR_CASES)
        async_stdlib.compile(workspace, "async_combinator_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run_case(source)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        return output
    end

    it("covers every any arity and positional result", function()
        local output = run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_any_variants()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "any-ok")
        ]])
        assert.match("combinator-logged-failure", output, 1, true)
    end)

    it("covers every race arity, tie, and terminal status", function()
        local output = run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_race_variants()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "race-ok")
        ]])
        assert.match("race-logged-failure", output, 1, true)
    end)

    it("covers every all arity, value tuple, and error position", function()
        local output = run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_all_variants()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "all-ok")
        ]])
        assert.match("all-logged-failure", output, 1, true)
    end)

    it("joins timer and I/O tasks and preserves complete statuses", function()
        local path = workspace .. "/joined.txt"
        local output = run_case(([=[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_join_and_status(%q)
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "join-ok")
        ]=]):format(path))
        assert.match("join-logged-failure", output, 1, true)
        local _, reports = output:gsub("uncaught error in async Task:", "")
        assert.equals(2, reports, output)
        assert.equals("joined-io", async_stdlib.read(path))
    end)

    it("exposes running, suspend, resume, and terminal listeners", function()
        local output = run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_task_primitives()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "primitives-ok")
        ]])
        assert.not_match("swallowed-listener-error", output, 1, true)
    end)

    it("cancels a Task suspended inside a combinator", function()
        run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_cancelled_combinator()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "cancelled-combinator-ok")
        ]])
    end)

    it("rejects the current Task after self-cancellation", function()
        run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_cancelled_self_rejection()
            async.loop()
            assert(task:status():as_string() == "cancelled")
            assert(cases.result() == "cancelled-self-rejected")
        ]])
    end)

    it("removes cancelled combinator listeners without retaining their Task",
    function()
        run_case([[
            local async = require "titan.async"
            local cases = require "async_combinator_cases"
            local task = cases.start_listener_cleanup()
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(cases.result() == "listener-cleanup-ok")
        ]])
    end)
end)

# Async combinators

These all depend on some fixes to `async` that drifted with the redesign:

1. `Task:status()` should not return a simple string, but this union (with a
few convenience methods for common operations):

```
union TaskStatus
  ready
  running
  waiting
  succeeded: value
  failed: Error
  cancelled: value
end

function TaskStatus:as_string(): string
  case self
  when ready
    return "ready"
  when running
    return "running"
  when waiting
    return "waiting"
  when succeeded
    return "succeeded"
  when failed
    return "failed"
  when cancelled
    return "cancelled"
  end
end

function TaskStatus:has_finished(): boolean
  case self
  when succeeded
    return true
  when failed
    return true
  when cancelled
    return true
  else
    return false
  end
end

function TaskStatus:has_succeeded(): (boolean, value?)
  case self
  when succeeded: v
    return true, v
  else 
    return false, nil
  end
end

function TaskStatus:has_failed(): (boolean, Error?)
  case self
  when failed: err
    return true, err
  else 
    return false, nil
  end
end

function TaskStatus:has_cancelled(): (boolean, value?)
  case self
  when cancelled: r
    return true, r
  else 
    return false, nil
  end
end
```

For `succeeded`, the payload is the value the task returned, for `failed`
it is the `Error` record of the error, and for `cancelled` the reason.

2. The `Error` record is missing a traceback.
3. The `Cancelled` record does not need to be exposed by `async`, and might not be
needed altogether.

The combinators in the rest of this doc are using `*_two`, `*_three`, `*_four`,
`*_five` versions instead of a variadic version so they can get more precise types
when parametric polymorphism is added.

They also depend a lower-level addition to the `uv` module to expose `uv_check_t`
handles so the waiting loop can use them and not enter a busy wait. Each call to
the combinator functions should create a handle, with a defer to close it,
and on each loop wait on the handle. The `uv_check_t` handle has a multi-shot callback,
similar to timers, so the wrapper for the handle should have a boolean flag and the
callback should implement this simple state machine:

```
no waiter -> set boolean to true and return to event loop
waiter present -> clear boolean and resume waiter
```

While the "wait for handle" call does this:

```
boolean is true -> clear boolean and return immediately
boolean is false -> yield to set waiter
```

This is wrapped by this high-level API in `async`:

```
function async.waiter(): Waiter -- creates the uv_check_t handle, calls uv_check_init and uv_check_start
function Waiter:wait() -- waits for the next check (may return immediately if the callback fired before being called)
function Waiter:close() -- uv_check_stop then uv_close the handle, waiting for the uv_close callback
```

The wait for the callback on closing the waiter is needed to prevent the handle from getting
garbage-collected before libuv is finished with it.

Using this the loops in the implementation of the combinators are not expensive,
because of the small and bounded number of tasks, the simple `switch/case` the
`case status` for the status of each task compiles to, and the non-busy wait nature,
which will make the event loop sleep if all tasks except the one doing waiting
are waiting for IO or a timer to fire.

# any

```
async.any_two(first: Task, second: Task): AnyTwoResult
async.any_three(first: Task, second: Task, third: Task): AnyThreeResult
async.any_four(first: Task, second: Task, third: Task, fourth: Task): AnyFourResult
async.any_five(first: Task, second: Task, third: Task, fourth: Task, fifth: Task): AnyFiveResult
```

Analogous to `Promise.any` in JavaScript, takes two to five tasks
and polls their status in a loop until the one of them finishes successfully
or all of them finish. It then returns a `AnyTwoResult`/`AnyThreeResult`/...
union:

```
union AnyTwoResult
  first: value
  second: value
  none
end
```

The `first`/`second` variants correspond to that task being the one to
finish successfully first. The `none` corresponds to all of them either
failing or being cancelled (the caller that is interested in the state of each
task should keep a reference to them and check`task:status()`).

The implementation loops, starting the loop with an `waiter:wait()` then
checking the status of each task in turn.

Returning early because a task finished does not cancel the other tasks, it is the
caller's responsibility to do that if they want this behavior.

```
-- reads from a socket within a five-second deadline
local res = async.any_two(
    async.run(function () return conn:read() end),
    async.run(function () timer.sleep(30000) end)
)
case res
when first: data
 -- handle data received
when second
 -- handle timeout
none
 -- handle error
end
```

# race

```
async.race_two(first: Task, second: Task): RaceTwoResult
async.race_three(first: Task, second: Task, third: Task): RaceThreeResult
async.race_four(first: Task, second: Task, third: Task, fourth: Task): RaceFourResult
async.race_five(first: Task, second: Task, third: Task, fourth: Task, fifth: Task): RaceFiveResult
```

Analogous to `Promise.race`, where the first task to finish either succcessfully or
not (including failing or being cancelled).

```
union RaceTwoResult
  first: TaskStatus
  second: TaskStatus
end
```

The race result only tells which task finished first, which the status as the payload,
the caller should `case` on it.

The implementation also loops, starting with `waiter:wait()` and then checking
each task in sequence.

Like with `any`, does not cancel the other racing tasks, it is the
caller's responsibility to do that if they want this behavior.


# all

```
async.all_two(first: Task, second: Task): (value, value)
async.all_three(first: Task, second: Task, third: Task): (value, value, value)
async.all_four(first: Task, second: Task, third: Task, fourth: Task): (value, value, value, value)
async.all_five(first: Task, second: Task, third: Task, fourth: Task, fifth: Task): (value, value, value, value, value)
```

Analogous to `Promise.all`, returns as multiple results the success value of each task because that
is the expected path. The first task that fails or is cancelled makes `all` raise an `All*Error` union:

```
union AllTwoError
  first: TaskStatus
  second: TaskStatus
end
```

The payload is the `TaskStatus` union for the task that failed or was cancelled, and the
catcher can `case` of it.

Uses the same loop implementation with `waiter:wait()` as the others.

Also does not cancel the other tasks in the case of an error result.

# join

```
async.join(task: Task): TaskStatus
async.join_two(first: Task, second: Task): (TaskStatus, TaskStatus)
async.join_three(first: Task, second: Task, third: Task): (TaskStatus, TaskStatus, TaskStatus)
async.join_four(first: Task, second: Task, third: Task, fourth: Task): (TaskStatus, TaskStatus, TaskStatus, TaskStatus)
async.join_five(first: Task, second: Task, third: Task, fourth: Task, fifth: Task): (TaskStatus, TaskStatus, TaskStatus, TaskStatus, TaskStatus)
```

Analogous to `Promise.allSettled`, waits for all tasks to finish, then returns the
final `TaskStatus` of each task.

Implemented as a loop that does `waiter:wait()` in each iteration then checks the
status of each task in sequence, until all tasks are finished, then returns
the status of each task.

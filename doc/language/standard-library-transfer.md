# Transfer policies

`import "transfer"` names `titan.transfer`, the independent-state value policy
module. `transfer.TransferValue` is the canonical union;
`async.TransferValue` remains a transparent alias of the same type. Existing
constructors, `from_value`, and `to_value` work through either spelling.

See [transfer values](async-io.md#transfer-values) for scalar, borrowed pointer,
protobuf, closure, and custom-record policies, including their lifetime rules.
This module does not create an async Runtime or deliver messages. It is usable
by native owner modules below the scheduler.

## Native resource handoff

Standard-library resource hooks perform a manual, exactly-once handoff. The
origin hook checks for pending work, snapshots buffered semantic state, and
detaches the origin owner before returning its payload. The destination hook
adopts that payload into fresh local wrappers. A failed send does not undo
detachment: the caller must recover the payload or dispose of its resource.
Do not replay or abandon owning native payloads.

UV-backed destinations require an existing active async Runtime. Its loop is
bound for reconstruction when the Runtime initializes and unbound as shutdown
begins. Reconstruction never creates or drives a Runtime implicitly. Pending
native requests count as pending work even after a Task has been cancelled.

Process lifetime handling stays in its original Runtime. Its communication
streams can move independently; the original Process still owns child exit
notification, waiting, and reaping.

The individual resource chapters document their supported states and guards.
An HTTP request and response move together as one `http.Exchange` because they
share the same parser and transport.

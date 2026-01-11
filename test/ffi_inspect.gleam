////
//// Mission: expose test-only inspection helpers for BEAM processes.
////
//// Responsibilities:
//// - Provide access to Erlang process metadata required by integration tests.
////
//// Non-responsibilities:
//// - Any production runtime behavior.
////
//// Relationships:
//// - Uses `sad_ffi` Erlang module functions.

import gleam/erlang/process.{type Pid}

/// Returns the current `message_queue_len` for a process.
///
/// This is intended for integration tests that assert mailbox boundedness.
pub fn message_queue_len(pid: Pid) -> Int {
  message_queue_len_ffi(pid)
}

@external(erlang, "sad_ffi", "message_queue_len")
fn message_queue_len_ffi(pid: Pid) -> Int

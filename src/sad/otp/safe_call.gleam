////
//// Mission: provide a safe OTP call helper for boundary processes (HTTP/SSE,
//// ephemeral workers) that must not crash on callee failures.
////
//// Responsibilities:
//// - Perform request/reply with an explicit `reply_to` subject.
//// - Monitor the callee and return `Disconnected` if it dies.
//// - Bound waiting time with a caller-provided timeout.
////
//// Non-responsibilities:
//// - Applying default timeouts (callers must pass `timeout_ms`).
//// - Retrying or buffering late replies.
////
//// Relationships:
//// - Used by streaming helpers (e.g. `sad/streams/sink`) to impose real backpressure.

import gleam/erlang/process.{
  type Down, type Subject, demonitor_process, monitor, new_selector, new_subject,
  select_map, select_specific_monitor, selector_receive, send, subject_owner,
}
import gleam/int

/// Errors returned by `call_within`.
///
/// These constructors are part of the public contract and must remain stable.
pub type CallError {
  Disconnected
  TimedOut
}

type CallEvt(reply) {
  GotReply(reply)
  CalleeDown(Down)
}

/// Performs a safe call against a `Subject(message)`.
///
/// Unlike `process.call`/`actor.call`, this function never crashes the caller:
/// it returns `Error(Disconnected)` if the subject is down, and `Error(TimedOut)`
/// if no reply arrives within `timeout_ms`.
///
/// The `make_message` callback receives a fresh `reply_to` subject that the callee
/// must reply to.
pub fn call_within(
  subject: Subject(message),
  timeout_ms: Int,
  make_message: fn(Subject(reply)) -> message,
) -> Result(reply, CallError) {
  let reply_subject = new_subject()

  case subject_owner(subject) {
    Error(_) -> Error(Disconnected)

    Ok(pid) -> {
      let monitor = monitor(pid)
      send(subject, make_message(reply_subject))

      let selector =
        new_selector()
        |> select_map(reply_subject, GotReply)
        |> select_specific_monitor(monitor, CalleeDown)

      let out = selector_receive(selector, int.max(timeout_ms, 1))
      demonitor_process(monitor)

      case out {
        Ok(GotReply(reply)) -> Ok(reply)
        Ok(CalleeDown(_)) -> Error(Disconnected)
        Error(Nil) -> Error(TimedOut)
      }
    }
  }
}

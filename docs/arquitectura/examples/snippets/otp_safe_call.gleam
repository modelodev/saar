// Extracted reference snippet (v0)
// Purpose: documentation-only; may not compile as-is.
//
// saar/otp/safe_call.gleam
//
// Safe-call para bordes (HTTP/SSE/workers efímeros): nunca debe tumbar al caller.
// Evita `process.call`/`actor.call` (fail-fast) y en su lugar usa:
// - reply_subject (reply explícito)
// - monitor del callee
// - selector_receive con timeout
//
// Nota sobre “late replies”:
// - Este patrón es seguro cuando el caller es efímero (handler HTTP / worker) o cuando,
//   tras `TimedOut`/`Disconnected`, deja de llamar al callee (p.ej. cambia a discard mode).
// - Si en el futuro necesitáramos seguir llamando tras timeout, usar un “helper process”
//   dueño del reply_subject para evitar acumulación de replies tardías en el mailbox.

import gleam/erlang/process
import gleam/erlang/process.{type Subject}

pub type CallError {
  Disconnected
  TimedOut
}

pub type ApiCallError(e) {
  Call(CallError)
  Domain(e)
}

type CallEvt(reply) {
  GotReply(reply)
  CalleeDown(process.Down)
}

pub fn call_within(
  subject: Subject(message),
  timeout_ms: Int,
  make_message: fn(Subject(reply)) -> message,
) -> Result(reply, CallError) {
  let reply_subject = process.new_subject()

  case process.subject_owner(subject) {
    Error(_) -> Error(Disconnected)
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      process.send(subject, make_message(reply_subject))

      let selector =
        process.new_selector()
        |> process.select_map(reply_subject, GotReply)
        |> process.select_specific_monitor(monitor, CalleeDown)

      let out = process.selector_receive(selector, timeout_ms)
      process.demonitor_process(monitor)

      case out {
        Ok(GotReply(reply)) -> Ok(reply)
        Ok(CalleeDown(_)) -> Error(Disconnected)
        Error(Nil) -> Error(TimedOut)
      }
    }
  }
}

/// Helper para el patrón común de actores: el mensaje incluye `reply_to: Subject(Result(a, e))`.
pub fn call_result_within(
  subject: Subject(message),
  timeout_ms: Int,
  make_message: fn(Subject(Result(a, e))) -> message,
) -> Result(a, ApiCallError(e)) {
  case call_within(subject, timeout_ms, make_message) {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(domain_error)) -> Error(Domain(domain_error))
    Error(call_error) -> Error(Call(call_error))
  }
}

//// Boundary helpers for calling core actors.
////
//// Mission: centralize the common `safe_call.call_within` plumbing used by
//// boundary layers (gateway, tests, adapters) to talk to core actors.
////
//// Responsibilities:
//// - Provide a single error shape for "call failed" vs "actor returned error".
//// - Keep boundary code small and consistent.
////
//// Non-responsibilities:
//// - Implementing any domain behavior.
//// - Hiding timeouts; callers must choose explicit timeouts.
////
//// Relationships:
//// - Wraps `sad/otp/safe_call.call_within`.
//// - Used by gateway and tests instead of `core/*_api.gleam` modules.

import gleam/erlang/process
import gleam/result
import sad/otp/safe_call

/// Error returned by boundary calls to core actors.
///
/// `CallFailed` indicates the actor could not be reached (down or timed out).
/// `ActorError` carries the domain error returned by the actor.
pub type ApiCallError(e) {
  CallFailed(safe_call.CallError)
  ActorError(e)
}

/// Calls an actor and returns its reply.
///
/// This is a thin wrapper over `safe_call.call_within`.
pub fn call(
  subject: process.Subject(msg),
  timeout_ms: Int,
  make_msg: fn(process.Subject(reply)) -> msg,
) -> Result(reply, safe_call.CallError) {
  safe_call.call_within(subject, timeout_ms, make_msg)
}

/// Calls an actor that replies with a `Result`.
///
/// Typical pattern for request/reply messages: the actor encodes domain failure
/// as `Result(value, error)`.
pub fn call_unwrap_result(
  subject: process.Subject(msg),
  timeout_ms: Int,
  make_msg: fn(process.Subject(Result(value, error))) -> msg,
) -> Result(value, ApiCallError(error)) {
  safe_call.call_within(subject, timeout_ms, make_msg)
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

////
//// Mission: define a small, ack-based sink protocol for streaming delivery.
////
//// Responsibilities:
//// - Provide `push_batch` and `finish` helpers that wait for an ACK.
//// - Expose a message protocol implemented by the gateway SSE loop.
////
//// Non-responsibilities:
//// - Batching policy (size/interval) lives in the producer.
//// - SSE framing, encoding, or HTTP concerns.
////
//// Relationships:
//// - Uses `sad/otp/safe_call` to avoid crashing boundary processes.
//// - Implemented by `sad/gateway/sse_loop` (one sink per request).

import gleam/erlang/process.{type Subject}
import sad/otp/safe_call.{type CallError, call_within}
import sad/types/output.{type InteractionError, type InteractionResult}
import sad/types/stream.{type StreamEvent}

/// A stream sink is a process subject that implements `StreamSinkMsg`.
///
/// The sink is expected to ACK only after it has written to the underlying
/// transport (e.g. an SSE socket), so the caller experiences real backpressure.
pub type StreamSink =
  Subject(StreamSinkMsg)

/// Messages supported by a `StreamSink`.
///
/// The ACK is a `Result(Nil, CallError)` sent to `reply_to`.
pub type StreamSinkMsg {
  /// Pushes a batch of fully-formed `StreamEvent` values.
  PushBatch(
    events: List(StreamEvent),
    reply_to: Subject(Result(Nil, CallError)),
  )

  /// Emits a terminal event and closes the stream.
  Finish(
    result: Result(InteractionResult, InteractionError),
    reply_to: Subject(Result(Nil, CallError)),
  )
}

/// Pushes a batch of events to the sink and waits for an ACK.
///
/// `Ok(Nil)` means the sink accepted the batch and wrote it to the transport.
/// `Error(Disconnected)` / `Error(TimedOut)` indicate the producer should stop
/// pushing and degrade to discard mode.
pub fn push_batch(
  sink: StreamSink,
  events: List(StreamEvent),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  call_within(sink, timeout_ms, fn(reply_to) { PushBatch(events, reply_to) })
  |> unwrap_call
}

/// Sends the final result to the sink so it can emit a terminal event and close.
pub fn finish(
  sink: StreamSink,
  result: Result(InteractionResult, InteractionError),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  call_within(sink, timeout_ms, fn(reply_to) { Finish(result, reply_to) })
  |> unwrap_call
}

fn unwrap_call(
  out: Result(Result(value, CallError), CallError),
) -> Result(value, CallError) {
  case out {
    Ok(value) -> value
    Error(err) -> Error(err)
  }
}

////
//// Mission: provide a small, ack-based sink protocol for streaming delivery.
////
//// Responsibilities:
//// - Provide `push_batch` and `finish` helpers that wait for an ACK.
//// - Provide an SSE-based sink loop implementation (`start_sse_sink`).
////
//// Non-responsibilities:
//// - Batching policy (size/interval) lives in the producer.
//// - Choosing adapter/wire protocol; callers provide `wire_event`.
////
//// Relationships:
//// - Uses `sad/otp/safe_call` to avoid crashing boundary processes.
//// - Used by `sad/streams/stream_pump` to apply backpressure.

import gleam/erlang/process
import gleam/json
import gleam/list
import sad/otp/safe_call.{type CallError, call_within}
import sad/types/core
import sad/types/output
import sad/types/stream.{type StreamEvent}

/// Minimal interface required to write SSE frames.
///
/// `write` must block until bytes are written (or fail) so ACK means "written".
pub type SseWriter {
  SseWriter(write: fn(String) -> Result(Nil, CallError), close: fn() -> Nil)
}

type StreamSinkMsg {
  /// Pushes a batch of fully-formed `StreamEvent` values.
  PushBatch(
    events: List(StreamEvent),
    reply_to: process.Subject(Result(Nil, CallError)),
  )

  /// Emits a terminal event and closes the stream.
  Finish(
    result: Result(output.InteractionResult, output.InteractionError),
    reply_to: process.Subject(Result(Nil, CallError)),
  )
}

/// A stream sink used by producers.
///
/// The underlying message protocol is intentionally hidden so only the provided
/// sink implementations are relied upon.
pub opaque type StreamSink {
  StreamSink(process.Subject(StreamSinkMsg))
}

/// Starts a `StreamSink` loop for a single SSE response.
///
/// `keep_alive_interval_ms` sends `: keep-alive\n\n` when idle. A value of `0`
/// disables keep-alives.
pub fn start_sse_sink(
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  keep_alive_interval_ms: Int,
) -> StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: process.Subject(StreamSinkMsg) = process.new_subject()
      process.send(ready, StreamSink(subject))
      loop(subject, writer, wire_event, keep_alive_interval_ms)
    })

  case process.receive(ready, 1000) {
    Ok(sink) -> sink
    Error(_) -> panic as "SSE sink did not start"
  }
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
  call_within(subject(sink), timeout_ms, fn(reply_to) {
    PushBatch(events, reply_to)
  })
  |> unwrap_call
}

/// Sends the final result to the sink so it can emit a terminal event and close.
pub fn finish(
  sink: StreamSink,
  result: Result(output.InteractionResult, output.InteractionError),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  call_within(subject(sink), timeout_ms, fn(reply_to) {
    Finish(result, reply_to)
  })
  |> unwrap_call
}

fn subject(sink: StreamSink) -> process.Subject(StreamSinkMsg) {
  let StreamSink(subject) = sink
  subject
}

fn unwrap_call(
  out: Result(Result(value, CallError), CallError),
) -> Result(value, CallError) {
  case out {
    Ok(value) -> value
    Error(err) -> Error(err)
  }
}

fn loop(
  subject: process.Subject(StreamSinkMsg),
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  keep_alive_interval_ms: Int,
) -> Nil {
  let timeout_ms = case keep_alive_interval_ms <= 0 {
    True -> 60_000
    False -> keep_alive_interval_ms
  }

  case process.receive(subject, timeout_ms) {
    Ok(PushBatch(events, reply_to)) -> {
      let out = write_batch(writer, wire_event, events)
      process.send(reply_to, out)

      case out {
        Ok(_) -> loop(subject, writer, wire_event, keep_alive_interval_ms)
        Error(_) -> writer_close(writer)
      }
    }

    Ok(Finish(result, reply_to)) -> {
      let out = write_finish(writer, result)
      process.send(reply_to, out)
      writer_close(writer)
    }

    Error(_) -> {
      // Best-effort keep-alive.
      case keep_alive_interval_ms <= 0 {
        True -> loop(subject, writer, wire_event, keep_alive_interval_ms)

        False -> {
          let _ = writer_write(writer, keep_alive_frame())
          loop(subject, writer, wire_event, keep_alive_interval_ms)
        }
      }
    }
  }
}

fn write_batch(
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  events: List(StreamEvent),
) -> Result(Nil, CallError) {
  events
  |> list.fold(Ok(Nil), fn(acc, event) {
    case acc {
      Ok(_) -> writer_write(writer, data_frame(wire_event(event)))
      Error(err) -> Error(err)
    }
  })
}

fn write_finish(
  writer: SseWriter,
  result: Result(output.InteractionResult, output.InteractionError),
) -> Result(Nil, CallError) {
  writer_write(writer, data_frame(terminal_payload(result)))
}

fn keep_alive_frame() -> String {
  ": keep-alive\n\n"
}

fn data_frame(payload: String) -> String {
  "data: " <> payload <> "\n\n"
}

fn terminal_payload(
  result: Result(output.InteractionResult, output.InteractionError),
) -> String {
  let payload = case result {
    Ok(output.InteractionResult(trace_id: trace_id, ..)) ->
      json.object([
        #("t", json.string("result")),
        #("trace_id", json.string(core.trace_id_to_string(trace_id))),
      ])

    Error(output.InteractionError(trace_id: trace_id, message: message, ..)) ->
      json.object([
        #("t", json.string("error")),
        #("trace_id", json.string(core.trace_id_to_string(trace_id))),
        #("detail", json.string(message)),
      ])
  }

  json.to_string(payload)
}

fn writer_write(writer: SseWriter, data: String) -> Result(Nil, CallError) {
  let SseWriter(write: write, ..) = writer
  write(data)
}

fn writer_close(writer: SseWriter) -> Nil {
  let SseWriter(close: close, ..) = writer
  close()
}

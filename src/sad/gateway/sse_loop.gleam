////
//// Mission: implement a per-request SSE loop that acts as a `StreamSink`.
////
//// Responsibilities:
//// - Receive `StreamSinkMsg` batches and write them to an SSE transport.
//// - ACK only after writes complete to impose real backpressure.
//// - Send periodic keep-alive comments (best-effort).
////
//// Non-responsibilities:
//// - Selecting the adapter/wire protocol (AG-UI/A2A/etc.).
//// - Buffering policies (batching lives in the producer).
////
//// Relationships:
//// - Implements `sad/streams/sink.StreamSinkMsg`.
//// - Uses `CallError` from `sad/otp/safe_call` to signal disconnect/timeout.

import gleam/erlang/process
import gleam/json
import gleam/list
import sad/otp/safe_call.{type CallError}
import sad/streams/sink
import sad/types/core
import sad/types/output
import sad/types/stream.{type StreamEvent}

/// Minimal interface required to write SSE frames.
///
/// `write` must block until bytes are written (or fail) so ACK means "written".
pub type SseWriter {
  SseWriter(write: fn(String) -> Result(Nil, CallError), close: fn() -> Nil)
}

/// Starts a `StreamSink` loop for a single SSE response.
///
/// `keep_alive_interval_ms` sends `: keep-alive\n\n` when idle. A value of `0`
/// disables keep-alives.
pub fn start(
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  keep_alive_interval_ms: Int,
) -> sink.StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      loop(subject, writer, wire_event, keep_alive_interval_ms)
    })

  case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "SSE loop did not start"
  }
}

fn loop(
  subject: sink.StreamSink,
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  keep_alive_interval_ms: Int,
) -> Nil {
  let timeout_ms = case keep_alive_interval_ms <= 0 {
    True -> 60_000
    False -> keep_alive_interval_ms
  }

  case process.receive(subject, timeout_ms) {
    Ok(sink.PushBatch(events, reply_to)) -> {
      let out = write_batch(writer, wire_event, events)
      process.send(reply_to, out)

      case out {
        Ok(_) -> loop(subject, writer, wire_event, keep_alive_interval_ms)
        Error(_) -> writer_close(writer)
      }
    }

    Ok(sink.Finish(result, reply_to)) -> {
      let out = write_finish(writer, result)
      process.send(reply_to, out)
      writer_close(writer)
    }

    Error(_) -> {
      // Best-effort keep-alive.
      case keep_alive_interval_ms <= 0 {
        True -> loop(subject, writer, wire_event, keep_alive_interval_ms)

        False -> {
          let _ = writer_write(writer, ": keep-alive\n\n")
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
      Ok(_) -> writer_write(writer, "data: " <> wire_event(event) <> "\n\n")
      Error(err) -> Error(err)
    }
  })
}

fn write_finish(
  writer: SseWriter,
  result: Result(output.InteractionResult, output.InteractionError),
) -> Result(Nil, CallError) {
  writer_write(writer, "data: " <> terminal_payload(result) <> "\n\n")
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

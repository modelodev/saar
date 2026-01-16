////
//// Mission: provide a small, ack-based sink protocol for streaming delivery.
////
//// Responsibilities:
//// - Provide `push_batch` and `finish` helpers that wait for an ACK.
//// - Provide an SSE-based sink loop implementation (`start_sse_sink`).
//// - Preserve the selected wire protocol as metadata on the sink.
////
//// Non-responsibilities:
//// - Batching policy (size/interval) lives in the producer.
//// - Producing protocol-specific payloads (AG-UI/A2UI/etc.).
////
//// Relationships:
//// - Uses `saar/otp/safe_call` to avoid crashing boundary processes.
//// - Used by `saar/streams/stream_pump` to apply backpressure.

import gleam/erlang/process
import gleam/list
import saar/otp/safe_call.{type CallError, call_within}
import saar/types/stream

/// Streaming wire protocols supported by the native gateway.
///
/// This value is metadata only: producers must serialize appropriate payloads.
pub type WireProtocol {
  AgUi
  A2uiV08
  A2a
  A2aA2uiV08
}

/// Minimal interface required to write SSE frames.
///
/// `write` must block until bytes are written (or fail) so ACK means "written".
pub type SseWriter {
  SseWriter(write: fn(String) -> Result(Nil, CallError), close: fn() -> Nil)
}

type StreamSinkMsg {
  /// Pushes a batch of fully-formed `StreamEvent` values.
  PushBatch(
    events: List(stream.StreamEvent),
    reply_to: process.Subject(Result(Nil, CallError)),
  )

  /// Closes the stream.
  Finish(reply_to: process.Subject(Result(Nil, CallError)))
}

/// A stream sink used by producers.
///
/// The underlying message protocol is intentionally hidden so only the provided
/// sink implementations are relied upon.
pub opaque type StreamSink {
  StreamSink(WireProtocol, process.Subject(StreamSinkMsg))
}

/// Streaming mode for an interaction.
///
/// `Streaming` carries the sink for event delivery.
pub type StreamMode {
  Streaming(StreamSink)
  NonStreaming
}

/// Returns the wire protocol attached to this sink.
pub fn protocol(sink: StreamSink) -> WireProtocol {
  let StreamSink(protocol, _) = sink
  protocol
}

/// Starts a `StreamSink` loop for a single SSE response.
///
/// `keep_alive_interval_ms` sends `: keep-alive\n\n` when idle. A value of `0`
/// disables keep-alives.
pub fn start_sse_sink(
  writer: SseWriter,
  protocol: WireProtocol,
  keep_alive_interval_ms: Int,
) -> StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: process.Subject(StreamSinkMsg) = process.new_subject()
      process.send(ready, StreamSink(protocol, subject))
      loop(subject, writer, keep_alive_interval_ms)
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
  events: List(stream.StreamEvent),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  call_within(subject(sink), timeout_ms, fn(reply_to) {
    PushBatch(events, reply_to)
  })
  |> unwrap_call
}

/// Closes the sink and waits for an ACK.
///
/// This does not emit a terminal event; protocols should decide whether to send
/// a final event before closing.
pub fn finish(sink: StreamSink, timeout_ms: Int) -> Result(Nil, CallError) {
  call_within(subject(sink), timeout_ms, fn(reply_to) { Finish(reply_to) })
  |> unwrap_call
}

fn subject(sink: StreamSink) -> process.Subject(StreamSinkMsg) {
  let StreamSink(_, subject) = sink
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
  keep_alive_interval_ms: Int,
) -> Nil {
  let timeout_ms = case keep_alive_interval_ms <= 0 {
    True -> 60_000
    False -> keep_alive_interval_ms
  }

  case process.receive(subject, timeout_ms) {
    Ok(PushBatch(events, reply_to)) -> {
      let out = write_batch(writer, events)
      process.send(reply_to, out)

      case out {
        Ok(_) -> loop(subject, writer, keep_alive_interval_ms)
        Error(_) -> writer_close(writer)
      }
    }

    Ok(Finish(reply_to)) -> {
      process.send(reply_to, Ok(Nil))
      writer_close(writer)
    }

    Error(_) -> {
      // Best-effort keep-alive.
      case keep_alive_interval_ms <= 0 {
        True -> loop(subject, writer, keep_alive_interval_ms)

        False -> {
          let _ = writer_write(writer, keep_alive_frame())
          loop(subject, writer, keep_alive_interval_ms)
        }
      }
    }
  }
}

fn write_batch(
  writer: SseWriter,
  events: List(stream.StreamEvent),
) -> Result(Nil, CallError) {
  events
  |> list.fold(Ok(Nil), fn(acc, event) {
    case acc {
      Ok(_) -> writer_write(writer, stream.payload(event))
      Error(err) -> Error(err)
    }
  })
}

fn keep_alive_frame() -> String {
  ": keep-alive\n\n"
}

fn writer_write(writer: SseWriter, data: String) -> Result(Nil, CallError) {
  let SseWriter(write: write, ..) = writer
  write(data)
}

fn writer_close(writer: SseWriter) -> Nil {
  let SseWriter(close: close, ..) = writer
  close()
}

////
//// Mission: provide a stable gateway-facing entry point for SSE sinks.
////
//// Responsibilities:
//// - Expose the per-request SSE sink starter used by the gateway.
////
//// Non-responsibilities:
//// - Implementing the sink protocol; delegated to `sad/streams/sink`.
////
//// Relationships:
//// - Thin wrapper around `sad/streams/sink.start_sse_sink`.

import sad/streams/sink
import sad/types/stream.{type StreamEvent}

pub type SseWriter =
  sink.SseWriter

pub fn start(
  writer: SseWriter,
  wire_event: fn(StreamEvent) -> String,
  keep_alive_interval_ms: Int,
) -> sink.StreamSink {
  sink.start_sse_sink(writer, wire_event, keep_alive_interval_ms)
}

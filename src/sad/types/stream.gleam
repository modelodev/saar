////
//// Mission: define typed streaming events emitted during an interaction.
////
//// Responsibilities:
//// - Provide a small, stable event set for streaming transports.
//// - Carry `trace_id` and timestamps for correlation.
////
//// Non-responsibilities:
//// - SSE framing, encoding, or delivery guarantees.
//// - Adapter-specific envelopes (AG-UI/A2A/etc.).
////
//// Relationships:
//// - Used by `sad/streams/*` modules and gateway SSE loops.
//// - Reuses `TraceId` from `sad/types/core` and `InteractionError` from `sad/types/output`.

import sad/ffi
import sad/types/core.{type TraceId}
import sad/types/output.{type InteractionError}

/// Streaming events emitted while an interaction is running.
///
/// These events are transport-agnostic (no SSE framing).
pub type StreamEvent {
  /// Marks the start of a stream.
  StreamStarted(trace_id: TraceId, timestamp: Int)

  /// A chunk of streamed textual content.
  ContentChunk(trace_id: TraceId, content: String, timestamp: Int)

  /// Marks the end of a stream (success path).
  StreamFinished(trace_id: TraceId, timestamp: Int)

  /// Marks the end of a stream due to an error.
  StreamError(trace_id: TraceId, error: InteractionError, timestamp: Int)
}

/// Builds a `StreamStarted` event with a fresh timestamp.
pub fn stream_started(trace_id: TraceId) -> StreamEvent {
  StreamStarted(trace_id: trace_id, timestamp: ffi.now_ms())
}

/// Builds a `ContentChunk` event with a fresh timestamp.
pub fn content_chunk(trace_id: TraceId, content: String) -> StreamEvent {
  ContentChunk(trace_id: trace_id, content: content, timestamp: ffi.now_ms())
}

/// Builds a `StreamFinished` event with a fresh timestamp.
pub fn stream_finished(trace_id: TraceId) -> StreamEvent {
  StreamFinished(trace_id: trace_id, timestamp: ffi.now_ms())
}

/// Builds a `StreamError` event with a fresh timestamp.
pub fn stream_error(trace_id: TraceId, error: InteractionError) -> StreamEvent {
  StreamError(trace_id: trace_id, error: error, timestamp: ffi.now_ms())
}

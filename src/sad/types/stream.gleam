////
//// Mission: represent streaming events as wire payloads.
////
//// Responsibilities:
//// - Carry already-serialized payloads for SSE `data:` frames.
//// - Provide small helpers to build and size events.
////
//// Non-responsibilities:
//// - Selecting or implementing higher-level wire protocols (AG-UI/A2UI).
//// - SSE framing (`data: ...\n\n`) and transport concerns.
////
//// Relationships:
//// - Produced by bridge workers and consumed by `sad/streams/*`.

import gleam/string

/// A single streaming event payload.
///
/// `payload` is the exact string written after `data: ` in SSE frames.
pub opaque type StreamEvent {
  StreamEvent(payload: String)
}

/// Builds a `StreamEvent` from a wire payload.
///
/// Example:
/// ```gleam
/// stream.event("{\"type\":\"RUN_STARTED\"}")
/// ```
pub fn event(payload: String) -> StreamEvent {
  StreamEvent(payload: payload)
}

/// Returns the payload carried by the event.
pub fn payload(event: StreamEvent) -> String {
  let StreamEvent(payload: payload) = event
  payload
}

/// Returns the UTF-8 byte size of the payload.
///
/// This is used for batching and backpressure accounting.
pub fn byte_size(event: StreamEvent) -> Int {
  event |> payload |> string.byte_size
}

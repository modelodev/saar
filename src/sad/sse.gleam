////
//// Mission: build Server-Sent Events (SSE) frames as strings.
////
//// Responsibilities:
//// - Provide stable helpers to format `data:` and `event:` + `data:` frames.
//// - Provide comment frames for keep-alives.
////
//// Non-responsibilities:
//// - Writing to sockets or handling backpressure.
//// - Serializing JSON values (callers pass JSON strings).
////
//// Relationships:
//// - Used by protocol adapters (AG-UI/A2UI/A2A) to produce exact wire output.
//// - Consumed by `sad/types/stream.StreamEvent` payloads.

/// Formats a plain SSE `data:` frame.
///
/// The returned string includes the trailing blank line (`\n\n`).
///
/// Example:
/// ```gleam
/// sse.line("{\"ok\":true}")
/// // => "data: {\"ok\":true}\n\n"
/// ```
pub fn line(payload: String) -> String {
  "data: " <> payload <> "\n\n"
}

/// Formats a named SSE event with its `data:` payload.
///
/// The returned string includes the trailing blank line (`\n\n`).
///
/// Example:
/// ```gleam
/// sse.named_event("task_status", "{\"taskId\":\"t\"}")
/// // => "event: task_status\ndata: {\"taskId\":\"t\"}\n\n"
/// ```
pub fn named_event(name: String, payload: String) -> String {
  "event: " <> name <> "\n" <> "data: " <> payload <> "\n\n"
}

/// Formats an SSE comment frame.
///
/// The returned string includes the trailing blank line (`\n\n`).
pub fn comment(text: String) -> String {
  ": " <> text <> "\n\n"
}

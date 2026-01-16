//// JSONL framing utilities.
////
//// Mission: incrementally frame newline-delimited JSON (JSONL) lines from
//// arbitrary stdout chunks.
////
//// Responsibilities:
//// - Maintain a buffer of partial output.
//// - Extract complete lines split by `\n`.
//// - Enforce a maximum event size to prevent unbounded buffering.
////
//// Non-responsibilities:
//// - Parsing JSON or decoding runner events.
//// - Performing port I/O or timeouts.
////
//// Relationships:
//// - Used by `saar/bridge/port_process` to implement `read_line`.

import gleam/option.{type Option, None, Some}
import gleam/string

/// Framing errors.
pub type FramerError {
  /// The buffered event exceeded the configured maximum size.
  OversizedEvent(size: Int, max: Int)
  /// The stream ended with an unterminated line (no trailing newline).
  NoeolFragment(String)
}

/// Stateful JSONL framer.
pub type Framer {
  Framer(max_bytes: Int, buffer: String)
}

/// Create a new framer with an empty buffer.
pub fn init(max_bytes: Int) -> Framer {
  Framer(max_bytes: max_bytes, buffer: "")
}

/// Create a framer from an existing buffer.
pub fn from_buffer(max_bytes: Int, buffer: String) -> Framer {
  Framer(max_bytes: max_bytes, buffer: buffer)
}

/// Extract the current buffer string.
pub fn buffer(framer: Framer) -> String {
  let Framer(buffer: buffer, ..) = framer
  buffer
}

/// Append a chunk to the buffer, enforcing the maximum size.
///
/// This does not extract lines; call `pop_line` after a successful append.
pub fn push_chunk(
  framer: Framer,
  chunk: String,
) -> #(Framer, Result(Nil, FramerError)) {
  let Framer(max_bytes: max_bytes, buffer: buffer) = framer
  let next_buffer = buffer <> chunk

  case string.byte_size(next_buffer) > max_bytes {
    True -> #(
      Framer(max_bytes: max_bytes, buffer: ""),
      Error(OversizedEvent(size: string.byte_size(next_buffer), max: max_bytes)),
    )
    False -> #(Framer(max_bytes: max_bytes, buffer: next_buffer), Ok(Nil))
  }
}

/// Pop the next complete line from the buffer.
///
/// Returns `Ok(None)` when no newline is present in the buffer.
pub fn pop_line(
  framer: Framer,
) -> #(Framer, Result(Option(String), FramerError)) {
  let Framer(max_bytes: max_bytes, buffer: buffer) = framer

  case string.split_once(buffer, on: "\n") {
    Error(_) -> #(framer, Ok(None))

    Ok(#(line, rest)) ->
      case string.byte_size(line) > max_bytes {
        True -> #(
          Framer(max_bytes: max_bytes, buffer: ""),
          Error(OversizedEvent(size: string.byte_size(line), max: max_bytes)),
        )
        False -> #(Framer(max_bytes: max_bytes, buffer: rest), Ok(Some(line)))
      }
  }
}

/// Finalize framing on stream end.
///
/// If the buffer is not empty, this returns `NoeolFragment` and clears it.
pub fn finalize(framer: Framer) -> #(Framer, Result(Nil, FramerError)) {
  let Framer(max_bytes: max_bytes, buffer: buffer) = framer

  case string.is_empty(buffer) {
    True -> #(framer, Ok(Nil))
    False -> #(
      Framer(max_bytes: max_bytes, buffer: ""),
      Error(NoeolFragment(buffer)),
    )
  }
}

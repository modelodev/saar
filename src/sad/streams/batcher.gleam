////
//// Mission: group streaming events into batches bounded by byte size and time.
////
//// Responsibilities:
//// - Accumulate events until `batch_byte_size` is reached.
//// - Flush buffered events when `flush_interval_ms` elapses.
////
//// Non-responsibilities:
//// - Writing to transports (SSE sockets) or applying backpressure.
//// - Encoding events to JSON/wire format.
////
//// Relationships:
//// - Used by producer loops (e.g. `sad/streams/stream_pump`) to control buffering.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type BatcherConfig {
  BatcherConfig(batch_byte_size: Int, flush_interval_ms: Int)
}

pub type Batcher(event) {
  Batcher(buffered: List(event), buffered_bytes: Int, last_flush_ms: Int)
}

/// Creates an empty batcher.
pub fn new(now_ms: Int) -> Batcher(event) {
  Batcher(buffered: [], buffered_bytes: 0, last_flush_ms: now_ms)
}

/// Adds an event to the batcher.
///
/// Returns `Some(batch)` when the batch should be flushed immediately.
pub fn push(
  event_size: fn(event) -> Int,
  cfg: BatcherConfig,
  batcher: Batcher(event),
  event: event,
  now_ms: Int,
) -> #(Batcher(event), Option(List(event))) {
  let BatcherConfig(batch_byte_size: batch_byte_size, ..) = cfg
  let Batcher(
    buffered: buffered,
    buffered_bytes: buffered_bytes,
    last_flush_ms: last_flush_ms,
  ) = batcher

  let next_bytes = buffered_bytes + int.max(event_size(event), 0)
  let next_buffered = [event, ..buffered]

  case next_bytes >= int.max(batch_byte_size, 1) {
    True -> {
      let batch = next_buffered |> list.reverse
      #(
        Batcher(buffered: [], buffered_bytes: 0, last_flush_ms: now_ms),
        Some(batch),
      )
    }

    False -> {
      #(
        Batcher(
          buffered: next_buffered,
          buffered_bytes: next_bytes,
          last_flush_ms: last_flush_ms,
        ),
        None,
      )
    }
  }
}

/// Flushes the buffered events if the interval has elapsed.
pub fn flush_if_due(
  cfg: BatcherConfig,
  batcher: Batcher(event),
  now_ms: Int,
) -> #(Batcher(event), Option(List(event))) {
  let BatcherConfig(flush_interval_ms: flush_interval_ms, ..) = cfg
  let Batcher(buffered: buffered, last_flush_ms: last_flush_ms, ..) = batcher

  case buffered {
    [] -> #(batcher, None)

    _ -> {
      let interval = int.max(flush_interval_ms, 0)

      case interval == 0 || now_ms - last_flush_ms >= interval {
        True -> {
          let batch = buffered |> list.reverse
          #(
            Batcher(buffered: [], buffered_bytes: 0, last_flush_ms: now_ms),
            Some(batch),
          )
        }

        False -> #(batcher, None)
      }
    }
  }
}

/// Flushes any buffered events.
pub fn flush(
  batcher: Batcher(event),
  now_ms: Int,
) -> #(Batcher(event), Option(List(event))) {
  let Batcher(buffered: buffered, ..) = batcher

  case buffered {
    [] -> #(batcher, None)
    _ -> #(
      Batcher(buffered: [], buffered_bytes: 0, last_flush_ms: now_ms),
      Some(buffered |> list.reverse),
    )
  }
}

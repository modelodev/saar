////
//// Mission: pump interaction stream events to a `StreamSink` with bounded buffering.
////
//// Responsibilities:
//// - Batch events by size/interval before calling `StreamSink.push_batch`.
//// - Apply real backpressure via sink ACKs.
//// - Degrade to discard mode on `TimedOut`/`Disconnected` without cancelling.
//// - Always emit the final result on `done`.
////
//// Non-responsibilities:
//// - Reading runner output or mapping external protocols.
//// - Owning long-lived buffering after disconnect (discard is v0 policy).
////
//// Relationships:
//// - Uses `sad/streams/batcher` for bounded buffering.
//// - Uses `sad/streams/sink` for ack-based delivery.

import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import sad/ffi
import sad/streams/batcher
import sad/streams/sink
import sad/types/config as types_config
import sad/types/output
import sad/types/stream.{type StreamEvent, ContentChunk}

type StreamPumpMsg {
  Push(event: StreamEvent)
  Finish(result: Result(output.InteractionResult, output.InteractionError))
}

/// Handle for pushing and finishing a stream.
pub opaque type StreamPump {
  StreamPump(process.Subject(StreamPumpMsg))
}

type Mode {
  Active(sink.StreamSink)
  Discard
}

/// Starts a stream pump.
///
/// When finished, the pump sends the final `Result` to `done`.
pub fn start(
  done: process.Subject(
    Result(output.InteractionResult, output.InteractionError),
  ),
  maybe_sink: Option(sink.StreamSink),
  cfg: types_config.InteractionStreamConfig,
) -> StreamPump {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let inbox: process.Subject(StreamPumpMsg) = process.new_subject()
      process.send(ready, StreamPump(inbox))

      let mode = case maybe_sink {
        Some(s) -> Active(s)
        None -> Discard
      }

      let types_config.InteractionStreamConfig(
        batch_byte_size: batch_byte_size,
        flush_interval_ms: flush_interval_ms,
        push_timeout_ms: push_timeout_ms,
      ) = cfg

      let now_ms = ffi.now_ms()
      let batcher_cfg =
        batcher.BatcherConfig(
          batch_byte_size: batch_byte_size,
          flush_interval_ms: flush_interval_ms,
        )

      let batch_state = batcher.new(now_ms)

      loop(inbox, done, mode, batcher_cfg, batch_state, push_timeout_ms)
    })

  case process.receive(ready, 1000) {
    Ok(pump) -> pump
    Error(_) -> panic as "Stream pump did not start"
  }
}

/// Sends an event to the pump.
pub fn push(pump: StreamPump, event: StreamEvent) -> Nil {
  process.send(subject(pump), Push(event))
}

/// Signals that the interaction has finished.
pub fn finish(
  pump: StreamPump,
  result: Result(output.InteractionResult, output.InteractionError),
) -> Nil {
  process.send(subject(pump), Finish(result))
}

/// Returns the pump process pid.
///
/// This is intended for tests and diagnostics.
pub fn pid(pump: StreamPump) -> Result(process.Pid, Nil) {
  case process.subject_owner(subject(pump)) {
    Ok(pid) -> Ok(pid)
    Error(_) -> Error(Nil)
  }
}

fn subject(pump: StreamPump) -> process.Subject(StreamPumpMsg) {
  let StreamPump(subject) = pump
  subject
}

fn loop(
  inbox: process.Subject(StreamPumpMsg),
  done: process.Subject(
    Result(output.InteractionResult, output.InteractionError),
  ),
  mode: Mode,
  cfg: batcher.BatcherConfig,
  state: batcher.Batcher(StreamEvent),
  push_timeout_ms: Int,
) -> Nil {
  let now_ms = ffi.now_ms()
  let timeout_ms = next_receive_timeout_ms(cfg, state, now_ms)

  case process.receive(inbox, timeout_ms) {
    Ok(Push(event)) -> {
      let now_ms = ffi.now_ms()
      let #(state, maybe_flush) =
        batcher.push(stream_event_bytes, cfg, state, event, now_ms)

      let #(mode, state) = case maybe_flush {
        None -> #(mode, state)
        Some(batch) -> {
          let mode = flush_batch(mode, batch, push_timeout_ms)
          #(mode, state)
        }
      }

      loop(inbox, done, mode, cfg, state, push_timeout_ms)
    }

    Ok(Finish(result)) -> {
      let now_ms = ffi.now_ms()
      let #(_state, maybe_flush) = batcher.flush(state, now_ms)
      let mode = case maybe_flush {
        None -> mode
        Some(batch) -> flush_batch(mode, batch, push_timeout_ms)
      }

      let _ = finish_sink(mode, result, push_timeout_ms)
      process.send(done, result)
      Nil
    }

    Error(_) -> {
      let now_ms = ffi.now_ms()
      let #(state, maybe_flush) = batcher.flush_if_due(cfg, state, now_ms)

      let #(mode, state) = case maybe_flush {
        None -> #(mode, state)
        Some(batch) -> {
          let mode = flush_batch(mode, batch, push_timeout_ms)
          #(mode, state)
        }
      }

      loop(inbox, done, mode, cfg, state, push_timeout_ms)
    }
  }
}

fn flush_batch(
  mode: Mode,
  batch: List(StreamEvent),
  push_timeout_ms: Int,
) -> Mode {
  case mode {
    Discard -> Discard

    Active(s) ->
      case sink.push_batch(s, batch, push_timeout_ms) {
        Ok(_) -> Active(s)
        Error(_) -> Discard
      }
  }
}

fn finish_sink(
  mode: Mode,
  result: Result(output.InteractionResult, output.InteractionError),
  push_timeout_ms: Int,
) -> Nil {
  case mode {
    Discard -> Nil
    Active(s) -> {
      let _ = sink.finish(s, result, push_timeout_ms)
      Nil
    }
  }
}

fn stream_event_bytes(event: StreamEvent) -> Int {
  case event {
    ContentChunk(content: content, ..) -> string.byte_size(content)
    _ -> 64
  }
}

fn next_receive_timeout_ms(
  cfg: batcher.BatcherConfig,
  state: batcher.Batcher(StreamEvent),
  now_ms: Int,
) -> Int {
  let batcher.BatcherConfig(flush_interval_ms: flush_interval_ms, ..) = cfg
  let batcher.Batcher(buffered: buffered, last_flush_ms: last_flush_ms, ..) =
    state

  case buffered {
    [] -> 60_000
    _ -> {
      let interval = int.max(flush_interval_ms, 0)
      case interval == 0 {
        True -> 0
        False -> int.max(0, last_flush_ms + interval - now_ms)
      }
    }
  }
}

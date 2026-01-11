import ffi_inspect
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sad/gateway/sse_loop
import sad/otp/safe_call
import sad/streams/sink
import sad/streams/stream_pump
import sad/types/config as types_config
import sad/types/core
import sad/types/enums as types_enums
import sad/types/output
import sad/types/stream

pub fn main() {
  gleeunit.main()
}

pub fn interaction_backpressure_or_discard_under_pressure() {
  let done = process.new_subject()

  // Sink ACK is slower than push_timeout_ms, forcing TimedOut and discard.
  let stream_sink = start_sink(writer_slow_ack(200))

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 25,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)

  let pump_pid = case stream_pump.pid(pump) {
    Ok(pid) -> pid
    Error(_) -> panic as "pump has no pid"
  }

  let trace_id = core.trace_id("trace-pressure")
  let sender_done = process.new_subject()

  let _sender =
    process.spawn(fn() {
      send_chunks(pump, trace_id, 750)
      stream_pump.finish(pump, Ok(min_ok_result(trace_id)))
      process.send(sender_done, Nil)
    })

  let max_len = sample_max_queue_len(pump_pid, 8, 10)
  should.equal(max_len < 5000, True)

  let msg = case process.receive(done, 3000) {
    Ok(msg) -> msg
    Error(_) -> panic as "Did not receive done"
  }

  msg |> should.equal(Ok(min_ok_result(trace_id)))

  // Ensure the sink process is closed (the pump may have switched to Discard).
  sink.finish(stream_sink, Ok(min_ok_result(trace_id)), 2000) |> should.be_ok

  let _ = process.receive(sender_done, 1000)
  Nil
}

pub fn disconnect_does_not_cancel() {
  let done = process.new_subject()

  // A write failure simulates early client disconnect.
  let stream_sink = start_sink(writer_always_error(safe_call.Disconnected))

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 250,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)
  let trace_id = core.trace_id("trace-disconnect")

  send_chunks(pump, trace_id, 10)
  stream_pump.finish(pump, Ok(min_ok_result(trace_id)))

  case process.receive(done, 2000) {
    Ok(Ok(_)) -> Nil
    Ok(Error(_)) -> panic as "Unexpected error"
    Error(_) -> panic as "done missing after disconnect"
  }
}

pub fn sink_disconnect_switches_to_discard() {
  let done = process.new_subject()

  // Sink errors immediately. The pump must switch to discard and still finish.
  let stream_sink = start_sink(writer_always_error(safe_call.Disconnected))

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 250,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)
  let trace_id = core.trace_id("trace-switch")

  send_chunks(pump, trace_id, 250)
  stream_pump.finish(pump, Ok(min_ok_result(trace_id)))

  case process.receive(done, 2000) {
    Ok(Ok(_)) -> Nil
    Ok(Error(_)) -> panic as "Unexpected error"
    Error(_) -> panic as "done missing"
  }
}

pub fn mailbox_does_not_grow_unbounded() {
  let done = process.new_subject()

  // Slow sink triggers TimedOut, then discard should keep the mailbox bounded.
  let stream_sink = start_sink(writer_slow_ack(200))

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 25,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)

  let pump_pid = case stream_pump.pid(pump) {
    Ok(pid) -> pid
    Error(_) -> panic as "pump has no pid"
  }

  let trace_id = core.trace_id("trace-mailbox")

  let _sender =
    process.spawn(fn() {
      send_chunks(pump, trace_id, 1200)
      stream_pump.finish(pump, Ok(min_ok_result(trace_id)))
    })

  let max_len = sample_max_queue_len(pump_pid, 12, 10)
  should.equal(max_len < 8000, True)

  case process.receive(done, 3000) {
    Ok(Ok(_)) -> Nil
    Ok(Error(_)) -> panic as "Unexpected error"
    Error(_) -> panic as "done missing"
  }

  // Ensure the sink process is closed.
  sink.finish(stream_sink, Ok(min_ok_result(trace_id)), 2000) |> should.be_ok
}

pub fn finish_payload_is_valid_json() {
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  let stream_sink = sse_loop.start(writer, fn(_event) { "{}" }, 0)

  let trace_id = core.trace_id("trace-json")
  let err =
    output.InteractionError(
      kind: types_enums.InfraError,
      message: "bad \"quote\"",
      trace_id: trace_id,
    )

  sink.finish(stream_sink, Error(err), 1000) |> should.equal(Ok(Nil))

  let frame = case process.receive(writes, 1000) {
    Ok(frame) -> frame
    Error(_) -> panic as "Expected terminal payload write"
  }

  let #(head, _rest) = case string.split(frame, "\n\n") {
    [head, ..rest] -> #(head, rest)
    _ -> panic as "Unexpected SSE frame"
  }

  let payload = case string.split(head, "data: ") {
    ["", payload] -> payload
    _ -> panic as "Unexpected SSE data frame"
  }

  json.parse(payload, decode.dynamic) |> should.be_ok
}

pub fn keep_alive_format_is_correct() {
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  let _sink = sse_loop.start(writer, fn(_event) { "{}" }, 10)

  process.sleep(40)

  case process.receive(writes, 0) {
    Ok(data) -> data |> should.equal(": keep-alive\n\n")
    Error(_) -> panic as "Expected keep-alive write"
  }
}

pub fn keep_alive_can_be_disabled_with_zero() {
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  let _sink = sse_loop.start(writer, fn(_event) { "{}" }, 0)
  process.sleep(30)

  case process.receive(writes, 0) {
    Ok(_) -> panic as "Did not expect keep-alive when disabled"
    Error(_) -> Nil
  }
}

// --- Helpers ---

type WriterBehavior {
  WriterSlowAck(delay_ms: Int)
  WriterAlwaysError(err: safe_call.CallError)
}

fn writer_slow_ack(delay_ms: Int) -> WriterBehavior {
  WriterSlowAck(delay_ms)
}

fn writer_always_error(err: safe_call.CallError) -> WriterBehavior {
  WriterAlwaysError(err)
}

fn start_sink(behavior: WriterBehavior) -> sink.StreamSink {
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        case behavior {
          WriterSlowAck(delay_ms) -> {
            process.sleep(delay_ms)
            Ok(Nil)
          }
          WriterAlwaysError(err) -> Error(err)
        }
      },
      close: fn() { Nil },
    )

  sink.start_sse_sink(writer, fn(_event) { "{}" }, 0)
}

fn send_chunks(
  pump: stream_pump.StreamPump,
  trace_id: core.TraceId,
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let event = stream.content_chunk(trace_id, "x")
      stream_pump.push(pump, event)
      send_chunks(pump, trace_id, count - 1)
    }
  }
}

fn min_ok_result(trace_id: core.TraceId) -> output.InteractionResult {
  output.InteractionResult(
    data: output.ResponseData(content: None, metadata: dict.new()),
    artifacts: [],
    trace_id: trace_id,
  )
}

fn sample_max_queue_len(pid: process.Pid, samples: Int, sleep_ms: Int) -> Int {
  case samples {
    0 -> 0
    _ -> {
      let current = ffi_inspect.message_queue_len(pid)
      process.sleep(sleep_ms)
      let rest = sample_max_queue_len(pid, samples - 1, sleep_ms)
      case current > rest {
        True -> current
        False -> rest
      }
    }
  }
}

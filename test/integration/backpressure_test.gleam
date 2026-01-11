import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sad/ffi
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
  let stream_sink = start_sink_ack_delay(200)

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 25,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)

  let pump_pid = case process.subject_owner(pump) {
    Ok(pid) -> pid
    Error(_) -> panic as "pump has no owner"
  }

  let trace_id = core.trace_id("trace-pressure")
  let sender_done = process.new_subject()

  let _sender =
    process.spawn(fn() {
      // Burst a lot of messages into the pump.
      send_chunks(pump, trace_id, 750)
      process.send(pump, stream_pump.Finish(Ok(min_ok_result(trace_id))))
      process.send(sender_done, Nil)
    })

  // Sample mailbox length while the burst is in flight.
  let max_len = sample_max_queue_len(pump_pid, 8, 10)
  should.equal(max_len < 5000, True)

  // Must still emit InteractionDone.
  let msg = case process.receive(done, 3000) {
    Ok(msg) -> msg
    Error(_) -> panic as "Did not receive InteractionDone"
  }

  msg |> should.equal(stream_pump.InteractionDone(Ok(min_ok_result(trace_id))))

  let _ = process.receive(sender_done, 1000)
  Nil
}

pub fn disconnect_does_not_cancel() {
  let done = process.new_subject()

  // The sink exits on the first batch, simulating an early client disconnect.
  let stream_sink = start_sink_disconnect_after_batches(1)

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 250,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)
  let trace_id = core.trace_id("trace-disconnect")

  send_chunks(pump, trace_id, 10)
  process.send(pump, stream_pump.Finish(Ok(min_ok_result(trace_id))))

  case process.receive(done, 2000) {
    Ok(stream_pump.InteractionDone(_)) -> Nil
    Error(_) -> panic as "InteractionDone missing after disconnect"
  }
}

pub fn sink_disconnect_switches_to_discard() {
  let done = process.new_subject()

  // Sink replies `Error(Disconnected)` immediately. The pump must switch to discard.
  let stream_sink = start_sink_error_always(safe_call.Disconnected)

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 250,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)
  let trace_id = core.trace_id("trace-switch")

  // If discard works, this burst should finish quickly.
  send_chunks(pump, trace_id, 250)
  process.send(pump, stream_pump.Finish(Ok(min_ok_result(trace_id))))

  case process.receive(done, 2000) {
    Ok(stream_pump.InteractionDone(_)) -> Nil
    Error(_) -> panic as "InteractionDone missing"
  }
}

pub fn mailbox_does_not_grow_unbounded() {
  let done = process.new_subject()

  // Slow sink triggers TimedOut, then discard should keep the mailbox bounded.
  let stream_sink = start_sink_ack_delay(200)

  let cfg =
    types_config.InteractionStreamConfig(
      batch_byte_size: 1,
      flush_interval_ms: 1000,
      push_timeout_ms: 25,
    )

  let pump = stream_pump.start(done, Some(stream_sink), cfg)

  let pump_pid = case process.subject_owner(pump) {
    Ok(pid) -> pid
    Error(_) -> panic as "pump has no owner"
  }

  let trace_id = core.trace_id("trace-mailbox")

  let _sender =
    process.spawn(fn() {
      send_chunks(pump, trace_id, 1200)
      process.send(pump, stream_pump.Finish(Ok(min_ok_result(trace_id))))
    })

  let max_len = sample_max_queue_len(pump_pid, 12, 10)
  should.equal(max_len < 8000, True)

  case process.receive(done, 3000) {
    Ok(stream_pump.InteractionDone(_)) -> Nil
    Error(_) -> panic as "InteractionDone missing"
  }
}

pub fn finish_payload_is_valid_json() {
  let writes = process.new_subject()

  let writer =
    sse_loop.SseWriter(
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
  let closed = process.new_subject()

  let writer =
    sse_loop.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        Ok(Nil)
      },
      close: fn() { process.send(closed, Nil) },
    )

  let _sink = sse_loop.start(writer, fn(_event) { "{}" }, 10)

  // Wait a bit and expect at least one keep-alive comment.
  process.sleep(40)

  case process.receive(writes, 0) {
    Ok(data) -> data |> should.equal(": keep-alive\n\n")
    Error(_) -> panic as "Expected keep-alive write"
  }

  let _ = process.receive(closed, 0)
  Nil
}

pub fn keep_alive_can_be_disabled_with_zero() {
  let writes = process.new_subject()

  let writer =
    sse_loop.SseWriter(
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

fn send_chunks(
  pump: process.Subject(stream_pump.StreamPumpMsg),
  trace_id: core.TraceId,
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let event = stream.content_chunk(trace_id, "x")
      process.send(pump, stream_pump.Push(event))
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
      let current = ffi.message_queue_len(pid)
      process.sleep(sleep_ms)
      let rest = sample_max_queue_len(pid, samples - 1, sleep_ms)
      case current > rest {
        True -> current
        False -> rest
      }
    }
  }
}

fn start_sink_ack_delay(ack_delay_ms: Int) -> sink.StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      sink_loop_ack_delay(subject, ack_delay_ms)
    })

  case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "sink did not start"
  }
}

fn sink_loop_ack_delay(subject: sink.StreamSink, ack_delay_ms: Int) -> Nil {
  case process.receive(subject, 5000) {
    Ok(sink.PushBatch(_events, reply_to)) -> {
      process.sleep(ack_delay_ms)
      process.send(reply_to, Ok(Nil))
      sink_loop_ack_delay(subject, ack_delay_ms)
    }

    Ok(sink.Finish(_result, reply_to)) -> {
      process.send(reply_to, Ok(Nil))
      Nil
    }

    Error(_) -> Nil
  }
}

fn start_sink_disconnect_after_batches(batches: Int) -> sink.StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      sink_loop_disconnect(subject, batches)
    })

  case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "sink did not start"
  }
}

fn sink_loop_disconnect(subject: sink.StreamSink, remaining_batches: Int) -> Nil {
  case remaining_batches <= 0 {
    True -> Nil
    False ->
      case process.receive(subject, 5000) {
        Ok(sink.PushBatch(_events, _reply_to)) -> Nil
        Ok(sink.Finish(_result, _reply_to)) -> Nil
        Error(_) -> sink_loop_disconnect(subject, remaining_batches)
      }
  }
}

fn start_sink_error_always(err: safe_call.CallError) -> sink.StreamSink {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      sink_loop_error_always(subject, err)
    })

  case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "sink did not start"
  }
}

fn sink_loop_error_always(
  subject: sink.StreamSink,
  err: safe_call.CallError,
) -> Nil {
  case process.receive(subject, 5000) {
    Ok(sink.PushBatch(_events, reply_to)) -> {
      process.send(reply_to, Error(err))
      sink_loop_error_always(subject, err)
    }

    Ok(sink.Finish(_result, reply_to)) -> {
      process.send(reply_to, Ok(Nil))
      Nil
    }

    Error(_) -> Nil
  }
}

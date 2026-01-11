import gleam/dict
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should
import sad/ffi
import sad/otp/safe_call
import sad/streams/sink
import sad/types/core
import sad/types/output
import sad/types/stream

pub fn main() {
  gleeunit.main()
}

pub fn stream_sink_push_batch_is_ack_backpressure() {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      loop(subject, 50)
    })

  let stream_sink = case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "Did not receive sink subject"
  }

  let trace_id = core.trace_id("trace-1")
  let events = [stream.content_chunk(trace_id, "hello")]

  let t0 = ffi.now_ms()
  let result = sink.push_batch(stream_sink, events, 1000)
  let t1 = ffi.now_ms()

  result
  |> should.equal(Ok(Nil))
  should.equal(t1 - t0 >= 40, True)
}

pub fn stream_sink_finish_closes_stream() {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject: sink.StreamSink = process.new_subject()
      process.send(ready, subject)
      loop(subject, 0)
    })

  let stream_sink = case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "Did not receive sink subject"
  }

  let trace_id = core.trace_id("trace-2")

  let ok_result =
    output.InteractionResult(
      data: output.ResponseData(content: None, metadata: dict.new()),
      artifacts: [],
      trace_id: trace_id,
    )

  sink.finish(stream_sink, Ok(ok_result), 1000) |> should.equal(Ok(Nil))

  let events = [stream.content_chunk(trace_id, "late")]
  sink.push_batch(stream_sink, events, 1000)
  |> should.equal(Error(safe_call.Disconnected))
}

fn loop(subject: sink.StreamSink, ack_delay_ms: Int) -> Nil {
  case process.receive(subject, 5000) {
    Ok(sink.PushBatch(_events, reply_to)) -> {
      process.sleep(ack_delay_ms)
      process.send(reply_to, Ok(Nil))
      loop(subject, ack_delay_ms)
    }

    Ok(sink.Finish(_result, reply_to)) -> {
      process.send(reply_to, Ok(Nil))
      Nil
    }

    Error(_) -> loop(subject, ack_delay_ms)
  }
}

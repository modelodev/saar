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
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        process.sleep(50)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  let stream_sink = sink.start_sse_sink(writer, fn(_event) { "{}" }, 0)

  let trace_id = core.trace_id("trace-1")
  let events = [stream.content_chunk(trace_id, "hello")]

  let t0 = ffi.now_ms()
  let result = sink.push_batch(stream_sink, events, 1000)
  let t1 = ffi.now_ms()

  result |> should.equal(Ok(Nil))
  should.equal(t1 - t0 >= 40, True)

  // Ensure an SSE data frame was written.
  let _ = process.receive(writes, 1000)

  // Close the sink loop.
  let ok_result =
    output.InteractionResult(
      data: output.ResponseData(content: None, metadata: dict.new()),
      artifacts: [],
      trace_id: trace_id,
    )

  sink.finish(stream_sink, Ok(ok_result), 1000) |> should.equal(Ok(Nil))
  Nil
}

pub fn stream_sink_finish_closes_stream() {
  let writes = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        process.send(writes, data)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  let stream_sink = sink.start_sse_sink(writer, fn(_event) { "{}" }, 0)

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

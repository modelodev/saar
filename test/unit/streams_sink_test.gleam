import gleam/erlang/process
import gleeunit
import gleeunit/should
import saar/ffi
import saar/otp/safe_call
import saar/streams/sink
import saar/types/stream

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

  let stream_sink = sink.start_sse_sink(writer, sink.AgUi, 0)

  let events = [stream.event("hello")]

  let t0 = ffi.now_ms()
  let result = sink.push_batch(stream_sink, events, 1000)
  let t1 = ffi.now_ms()

  result |> should.equal(Ok(Nil))
  should.equal(t1 - t0 >= 40, True)

  // Ensure an SSE data frame was written.
  let _ = process.receive(writes, 1000)

  // Close the sink loop.
  sink.finish(stream_sink, 1000) |> should.equal(Ok(Nil))
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

  let stream_sink = sink.start_sse_sink(writer, sink.AgUi, 0)

  sink.finish(stream_sink, 1000) |> should.equal(Ok(Nil))

  let events = [stream.event("late")]
  sink.push_batch(stream_sink, events, 1000)
  |> should.equal(Error(safe_call.Disconnected))
}

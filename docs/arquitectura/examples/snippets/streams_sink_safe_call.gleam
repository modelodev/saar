// En sad/streams/sink.gleam
import gleam/erlang/process
import gleam/erlang/process.{type Subject}
import gleam/result
import sad/otp/safe_call
import sad/otp/safe_call.{type CallError}

pub type StreamSink =
  Subject(StreamSinkMsg)

pub type StreamSinkMsg {
  /// Batch = lista ordenada de `StreamEvent` completos (no framing SSE).
  /// El sink serializa y escribe al socket en el mismo orden.
  PushBatch(
    events: List(StreamEvent),
    reply_to: Subject(Result(Nil, CallError)),
  )
  /// Evento terminal: el sink debe emitir el evento final y cerrar el stream SSE.
  Finish(
    result: Result(InteractionResult, InteractionError),
    reply_to: Subject(Result(Nil, CallError)),
  )
}

/// Empuja un batch de `StreamEvent` al StreamSink.
/// `Ok` significa “aceptado y escrito” (o equivalente) para que la escritura al socket imponga backpressure.
/// Si el cliente se desconecta, la operación falla y el worker degrada a discard (sin cancelar la interacción).
pub fn push_batch(
  sink: StreamSink,
  events: List(StreamEvent),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  case
    safe_call.call_within(sink, timeout_ms, fn(reply_to) {
      PushBatch(events, reply_to)
    })
  {
    Ok(Ok(_)) -> Ok(Nil)
    Ok(Error(e)) -> Error(e)
    Error(e) -> Error(e)
  }
}

/// Envía el resultado final al StreamSink para que emita el evento terminal (y cierre SSE).
pub fn finish(
  sink: StreamSink,
  result: Result(InteractionResult, InteractionError),
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  case
    safe_call.call_within(sink, timeout_ms, fn(reply_to) {
      Finish(result, reply_to)
    })
  {
    Ok(Ok(_)) -> Ok(Nil)
    Ok(Error(e)) -> Error(e)
    Error(e) -> Error(e)
  }
}

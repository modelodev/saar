// Extracted reference snippet (v0)
// Purpose: documentation-only; may not compile as-is.
//
// sad/gateway/sse_stream_sink.gleam
//
// StreamSink de interacción implementado como loop SSE de Mist (1 por request).
// Backpressure real: el bridge llama `sink.push_batch(...)` como operación tipo call
// (`safe_call.call_within`) y espera ack antes de seguir leyendo del runner/SSE upstream.

import gleam/erlang/process.{type Subject}
import gleam/erlang/process
import mist
import sad/otp/safe_call.{type CallError}
import sad/types.{type StreamEvent, type InteractionResult, type InteractionError}

pub type StreamSink = Subject(StreamSinkMsg)

pub type StreamSinkMsg {
  PushBatch(events: List(StreamEvent), reply_to: Subject(Result(Nil, CallError)))
  Finish(result: Result(InteractionResult, InteractionError), reply_to: Subject(Result(Nil, CallError)))
}

pub fn start_stream_sink(
  // `sse` es el handle/ctx que Mist entrega al iniciar el SSE.
  sse: mist.Sse,
  // `wire` encapsula el encoder (AG-UI/A2A/A2UI) seleccionado para este request.
  wire: fn(StreamEvent) -> String,
) -> StreamSink {
  let subject = process.new_subject()

  // Pseudocódigo: Mist ofrece `server_sent_events(init, handler)` con un loop.
  // La idea es que *este loop es el “actor” del sink*.
  let _pid =
    process.spawn(fn() {
      loop(subject, sse, wire)
    })

  subject
}

fn loop(subject: StreamSink, sse: mist.Sse, wire: fn(StreamEvent) -> String) -> Nil {
  // Pseudocódigo de receive (en la implementación real se usaría el receive/selector de Gleam+Mist).
  let msg = process.receive(subject)
  case msg {
    PushBatch(events, reply_to) -> {
      // MUST: escribir en orden; si falla (disconnect), responder Error y terminar loop.
      let write_ok = write_events(sse, events, wire)
      process.send(reply_to, write_ok)
      case write_ok {
        Ok(_) -> loop(subject, sse, wire)
        Error(_) -> Nil
      }
    }
    Finish(result, reply_to) -> {
      // MUST: emitir evento terminal si aplica (AG-UI/A2A).
      // En A2UI “puro” puede ser un no-op y cerrar directamente.
      let finish_ok = write_finish_and_close(sse, result, wire)
      process.send(reply_to, finish_ok)
      Nil
    }
  }
}

fn write_events(
  sse: mist.Sse,
  events: List(StreamEvent),
  wire: fn(StreamEvent) -> String,
) -> Result(Nil, CallError) {
  // Cada evento se serializa y se envía con `mist.send_event(...)`.
  // Si el socket está cerrado: Error(Disconnected).
  // Si Mist señala timeout: Error(TimedOut).
  Ok(Nil)
}

fn write_finish_and_close(
  sse: mist.Sse,
  result: Result(InteractionResult, InteractionError),
  wire: fn(StreamEvent) -> String,
) -> Result(Nil, CallError) {
  Ok(Nil)
}


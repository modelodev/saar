// Extracted reference snippet (v0)
// Source: arquitectura/bridge.md:1498
// Purpose: documentation-only; may not compile as-is.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import httpp/sse

/// Conexión SSE activa.
/// Opaco: encapsula el estado de la conexión streaming.
pub opaque type SseConnection {
  SseConnection(
    /// Subject para controlar el manager de streaming (shutdown).
    control: Subject(sse.SSEManagerMessage),
    /// Subject donde se reciben eventos SSE.
    events: Subject(sse.SSEEvent),
  )
}

/// Evento recibido de una conexión SSE.
pub type SseEvent {
  /// Datos del evento (campo `data:`). `event:` e `id:` se ignoran en v0.
  SseData(String)
  /// Conexión cerrada por el servidor
  SseClosed
  /// No llegó ningún evento dentro del timeout (útil para aplicar deadline)
  SseTimeout
}

/// Abre una conexión SSE para streaming.
/// Usa `httpp/sse` (basado en hackney) para gestionar streaming y parsing SSE.
/// 
/// IMPORTANTE: `method` es `http.Method`, NO string.
pub fn open_sse(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(Json),
) -> Result(SseConnection, HttpError) {
  // El caller construye el request completo (método/headers/body).
  // Nota: `httpp/sse.event_source` NO añade `Accept: text/event-stream`; este wrapper lo fuerza.
  let req = build_request(method, url, headers, body)

  let events = process.new_subject()

  // Timeout aquí es solo para recibir status+headers iniciales.
  // El timeout total de interacción lo aplica SAD (deadline en el worker).
  sse.event_source(req, 5000, events)
  |> result.map(fn(pair) {
    let #(_client_ref, control) = pair
    SseConnection(control: control, events: events)
  })
  |> result.map_error(fn(err) {
    ConnectionError("SSE start failed: " <> string.inspect(err))
  })
}

/// Lee el siguiente evento SSE de la conexión.
/// Bloquea hasta que hay un evento, el timeout expira, o el servidor cierra.
pub fn sse_receive(conn: SseConnection, timeout_ms: Int) -> SseEvent {
  case process.receive(conn.events, timeout_ms) {
    Ok(sse.Event(_, _, data)) -> SseData(data)
    Ok(sse.Closed) -> SseClosed
    Error(_) -> SseTimeout
  }
}

/// Cierra una conexión SSE.
pub fn close_sse(conn: SseConnection) -> Nil {
  process.send(conn.control, sse.Shutdown)
}

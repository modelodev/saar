//// SSE upstream support.
////
//// Mission: open and consume Server-Sent Events (SSE) responses from HTTP
//// agents using the runner event contract.
////
//// Responsibilities:
//// - Open an SSE connection (Accept: text/event-stream).
//// - Parse SSE frames and emit `SseEvent` values.
//// - Provide a read loop that stops at `RunnerEventResult`.
////
//// Non-responsibilities:
//// - Retrying connections.
//// - Mapping results to `InteractionResult` (that belongs to the bridge).
////
//// Relationships:
//// - Uses `sad/bridge/runner_contract` to decode runner events.
//// - Uses `sad/bridge/http_client` for error types.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type ExitReason, type Subject}
import gleam/http.{type Method}
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import httpp/streaming
import sad/bridge/http_client
import sad/bridge/runner_contract
import sad/ffi
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/output as types_output
import sad/types/runner as types_runner

/// Active SSE connection.
pub opaque type SseConnection {
  SseConnection(control: Subject(SseManagerMessage), events: Subject(SseEvent))
}

/// Events received from an SSE connection.
pub type SseEvent {
  SseData(String)
  SseClosed
  SseTimeout
}

type SseManagerMessage {
  Shutdown
}

type SseState {
  SseState(buffer: String)
}

/// Opens an SSE connection.
///
/// This forces `Accept: text/event-stream` and uses `httpp/streaming`.
///
/// Note: `initial_response_timeout_ms` only bounds status+headers.
pub fn open_sse(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
  initial_response_timeout_ms: Int,
) -> Result(SseConnection, http_client.HttpError) {
  use req <- result.try(build_request(method, url, headers, body))

  let events: Subject(SseEvent) = process.new_subject()

  let handler =
    streaming.StreamingRequestHandler(
      req: req
        |> request.map(bytes_tree.from_string)
        |> request.set_header("accept", "text/event-stream")
        |> request.set_header("connection", "keep-alive"),
      initial_state: SseState(buffer: ""),
      on_data: fn(message, _response, state) {
        sse_on_data(events, message, state)
      },
      on_message: fn(message, _response, state) {
        sse_on_message(events, message, state)
      },
      on_error: fn(_err, _response, _state) {
        process.send(events, SseClosed)
        Error(process.Normal)
      },
      initial_response_timeout: int.max(initial_response_timeout_ms, 1),
    )

  streaming.start(handler)
  |> result.map(fn(started) {
    let #(_client_ref, control) = started
    SseConnection(control: control, events: events)
  })
  |> result.map_error(fn(_) { http_client.ConnectionError("SSE start failed") })
}

/// Receives the next SSE event.
pub fn sse_receive(conn: SseConnection, timeout_ms: Int) -> SseEvent {
  case process.receive(conn.events, timeout_ms) {
    Ok(event) -> event
    Error(_) -> SseTimeout
  }
}

/// Closes an SSE connection.
pub fn close_sse(conn: SseConnection) -> Nil {
  process.send(conn.control, Shutdown)
}

/// Reads SSE events until a `t="result"` is received.
///
/// Contract (v0): each SSE `data:` field is either empty/commentary (ignored)
/// or a JSON object with runner-style tags: `log`, `chunk`, `result`.
///
/// Errors:
/// - Connection closes without a result -> `InfraError`.
/// - Invalid JSON or unknown tags -> `InfraError`.
pub fn read_sse_until_result(
  conn: SseConnection,
  trace_id: types_core.TraceId,
  max_event_bytes: Int,
  timeout_ms: Int,
) -> Result(types_runner.RunnerResponse, types_output.InteractionError) {
  let deadline_ms = ffi.now_ms() + int.max(timeout_ms, 1)
  read_sse_loop(conn, trace_id, max_event_bytes, deadline_ms)
}

fn read_sse_loop(
  conn: SseConnection,
  trace_id: types_core.TraceId,
  max_event_bytes: Int,
  deadline_ms: Int,
) -> Result(types_runner.RunnerResponse, types_output.InteractionError) {
  case ffi.now_ms() >= deadline_ms {
    True ->
      Error(types_output.sad_error(
        trace_id,
        types_enums.InfraError,
        "SSE timeout",
      ))

    False ->
      case sse_receive(conn, 50) {
        SseTimeout ->
          read_sse_loop(conn, trace_id, max_event_bytes, deadline_ms)

        SseClosed ->
          Error(types_output.sad_error(
            trace_id,
            types_enums.InfraError,
            "SSE closed without result",
          ))

        SseData(data) ->
          case string.trim(data) {
            "" -> read_sse_loop(conn, trace_id, max_event_bytes, deadline_ms)

            _ ->
              case string.byte_size(data) > max_event_bytes {
                True ->
                  Error(types_output.sad_error(
                    trace_id,
                    types_enums.InfraError,
                    "SSE event too large",
                  ))

                False ->
                  runner_contract.decode_event(data)
                  |> result.map_error(fn(err) {
                    types_output.sad_error(
                      trace_id,
                      types_enums.InfraError,
                      "Invalid SSE event: " <> string.inspect(err),
                    )
                  })
                  |> result.try(fn(event) {
                    case event {
                      types_runner.RunnerEventLog(_, _) ->
                        read_sse_loop(
                          conn,
                          trace_id,
                          max_event_bytes,
                          deadline_ms,
                        )

                      types_runner.RunnerEventChunk(_) ->
                        read_sse_loop(
                          conn,
                          trace_id,
                          max_event_bytes,
                          deadline_ms,
                        )

                      types_runner.RunnerEventResult(response) -> Ok(response)

                      _ ->
                        Error(types_output.sad_error(
                          trace_id,
                          types_enums.InfraError,
                          "Unexpected SSE runner event",
                        ))
                    }
                  })
              }
          }
      }
  }
}

fn build_request(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
) -> Result(request.Request(String), http_client.HttpError) {
  request.to(url)
  |> result.map_error(fn(_) { http_client.InvalidUrl(url) })
  |> result.map(fn(req) {
    let req = request.set_method(req, method)

    let req =
      headers
      |> dict.to_list
      |> list.fold(req, fn(r, pair) { request.set_header(r, pair.0, pair.1) })

    case body {
      None -> req
      Some(payload) -> request.set_body(req, payload)
    }
  })
}

fn sse_on_message(
  events: Subject(SseEvent),
  message: SseManagerMessage,
  _state: SseState,
) -> Result(SseState, ExitReason) {
  case message {
    Shutdown -> {
      process.send(events, SseClosed)
      Error(process.Normal)
    }
  }
}

fn sse_on_data(
  events: Subject(SseEvent),
  message: streaming.Message,
  state: SseState,
) -> Result(SseState, ExitReason) {
  case message {
    streaming.Done -> {
      process.send(events, SseClosed)
      Error(process.Normal)
    }

    streaming.Bits(bits) -> {
      use incoming <- result.try(
        bit_array.to_string(bits)
        |> result.replace_error(
          process.Abnormal(dynamic.string("SSE non-UTF8")),
        ),
      )

      let SseState(buffer: buffer) = state
      let full = buffer <> incoming
      let parts = string.split(full, "\n\n")

      let candidates = list.take(parts, list.length(parts) - 1)
      let assert Ok(rest) = list.last(parts)

      candidates
      |> list.each(fn(block) { send_sse_block(events, block) })

      Ok(SseState(buffer: rest))
    }
  }
}

fn send_sse_block(events: Subject(SseEvent), block: String) -> Nil {
  let data =
    block
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case line {
        ":" <> _ -> Error(Nil)
        "data: " <> value | "data:" <> value -> Ok(value)
        _ -> Error(Nil)
      }
    })
    |> list.map(string.trim_end)
    |> string.join("\n")

  case string.trim(data) {
    "" -> Nil
    _ -> process.send(events, SseData(data))
  }
}

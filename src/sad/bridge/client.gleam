//// Bridge HTTP client utilities.
////
//// Mission: provide the bridge with a small HTTP client surface for:
//// - non-streaming HTTP requests (sync)
//// - upstream SSE streaming (text/event-stream)
//// - file fetching for multipart bodies.
////
//// Responsibilities:
//// - Execute HTTP requests with explicit timeouts and size limits.
//// - Provide SSE connection helpers and a strict receive loop.
//// - Keep HTTP/hackney details localized to the bridge edge.
////
//// Non-responsibilities:
//// - Routing or capability selection.
//// - Long-lived supervision or retries/backoff policies.
////
//// Relationships:
//// - Uses `sad/bridge/interpolator` for strict URL templating.
//// - Uses `sad/types/profile` for interface/health check configuration.
//// - Used by `sad/bridge/runner` for continuous health checks.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type ExitReason, type Subject}
import gleam/http.{type Method, Delete, Get, Post, Put}
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import httpp/hackney
import httpp/streaming
import sad/bridge/interpolator
import sad/bridge/runner_contract
import sad/ffi
import sad/net/port_check
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/profile as types_profile
import sad/types/runner as types_runner

/// Simplified HTTP response for bridge use.
pub type HttpResponse {
  HttpResponse(status: Int, headers: List(#(String, String)), body: String)
}

/// Small ADT for HTTP client failures.
pub type HttpError {
  ConnectionError(String)
  Timeout
  InvalidUrl(String)
  BodyTooLarge(size: Int, max: Int)
  InvalidUtf8Body
  Unexpected(String)
}

pub fn http_error_to_string(err: HttpError) -> String {
  case err {
    ConnectionError(msg) -> "Connection error: " <> msg
    Timeout -> "Request timeout"
    InvalidUrl(url) -> "Invalid URL: " <> url
    BodyTooLarge(size, max) ->
      "Response too large ("
      <> int.to_string(size)
      <> " > "
      <> int.to_string(max)
      <> ")"
    InvalidUtf8Body -> "Invalid UTF-8 response body"
    Unexpected(msg) -> "HTTP error: " <> msg
  }
}

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
/// This forces `Accept: text/event-stream` and uses `httpp/streaming` under the hood.
///
/// Note: `initial_response_timeout_ms` only bounds status+headers.
pub fn open_sse(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
  initial_response_timeout_ms: Int,
) -> Result(SseConnection, HttpError) {
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
  |> result.map_error(fn(_) { ConnectionError("SSE start failed") })
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

        SseData(data) -> {
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
}

/// Executes a synchronous HTTP request.
///
/// `max_body_bytes` is enforced for the response body.
pub fn request_sync(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
  timeout_ms: Int,
  max_body_bytes: Int,
) -> Result(HttpResponse, HttpError) {
  use req <- result.try(build_request(method, url, headers, body))

  let req =
    req
    |> request.map(bytes_tree.from_string)
    |> request.set_header("connection", "close")

  use client_ref <- result.try(start_async(req))

  let deadline_ms = ffi.now_ms() + int.max(timeout_ms, 1)

  use #(status, response_headers, body_bits) <- result.try(collect_response(
    deadline_ms,
    client_ref,
    max_body_bytes,
  ))

  hackney.close(client_ref)

  case bit_array.to_string(body_bits) {
    Ok(body_string) ->
      Ok(HttpResponse(
        status: status,
        headers: response_headers,
        body: body_string,
      ))
    Error(_) -> Error(InvalidUtf8Body)
  }
}

fn build_request(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
) -> Result(request.Request(String), HttpError) {
  request.to(url)
  |> result.map_error(fn(_) { InvalidUrl(url) })
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

fn start_async(
  req: request.Request(bytes_tree.BytesTree),
) -> Result(hackney.ClientRef, HttpError) {
  let url = req |> request.to_uri |> uri.to_string

  hackney.send(req.method, url, req.headers, req.body, [
    hackney.Async,
    hackney.Pool(False),
  ])
  |> result.map_error(hackney_error_to_http_error)
  |> result.try(fn(resp) {
    case resp {
      hackney.AsyncResponse(client_ref) -> Ok(client_ref)
      _ -> Error(Unexpected("Expected async response"))
    }
  })
}

type ResponseState {
  ResponseState(
    status: Option(Int),
    headers: Option(List(#(String, String))),
    chunks: List(BitArray),
    total_bytes: Int,
  )
}

fn collect_response(
  deadline_ms: Int,
  client_ref: hackney.ClientRef,
  max_body_bytes: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError) {
  collect_response_loop(
    deadline_ms,
    client_ref,
    int.max(max_body_bytes, 0),
    ResponseState(status: None, headers: None, chunks: [], total_bytes: 0),
  )
}

fn collect_response_loop(
  deadline_ms: Int,
  client_ref: hackney.ClientRef,
  max_body_bytes: Int,
  state: ResponseState,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError) {
  case deadline_reached(deadline_ms) {
    True -> {
      hackney.close(client_ref)
      Error(Timeout)
    }

    False -> {
      let selector =
        process.new_selector()
        |> hackney.selecting_http_message(mapping: fn(ref, message) {
          case ref == client_ref {
            True ->
              handle_sync_message(
                deadline_ms,
                client_ref,
                max_body_bytes,
                state,
                message,
              )
            False ->
              collect_response_loop(
                deadline_ms,
                client_ref,
                max_body_bytes,
                state,
              )
          }
        })

      case process.selector_receive(selector, 50) {
        Ok(inner) -> inner
        Error(_) ->
          collect_response_loop(deadline_ms, client_ref, max_body_bytes, state)
      }
    }
  }
}

fn handle_sync_message(
  deadline_ms: Int,
  client_ref: hackney.ClientRef,
  max_body_bytes: Int,
  state: ResponseState,
  message: hackney.HttppMessage,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError) {
  case message {
    hackney.Status(code) ->
      collect_response_loop(
        deadline_ms,
        client_ref,
        max_body_bytes,
        ResponseState(..state, status: Some(code)),
      )

    hackney.Headers(headers) ->
      collect_response_loop(
        deadline_ms,
        client_ref,
        max_body_bytes,
        ResponseState(
          ..state,
          headers: Some(
            list.map(headers, fn(h) { #(string.lowercase(h.0), h.1) }),
          ),
        ),
      )

    hackney.Binary(bits) -> {
      let next_total = state.total_bytes + bit_array.byte_size(bits)

      case next_total > max_body_bytes {
        True -> {
          hackney.close(client_ref)
          Error(BodyTooLarge(size: next_total, max: max_body_bytes))
        }

        False ->
          collect_response_loop(
            deadline_ms,
            client_ref,
            max_body_bytes,
            ResponseState(
              ..state,
              chunks: [bits, ..state.chunks],
              total_bytes: next_total,
            ),
          )
      }
    }

    hackney.DoneStreaming -> finalize_sync_state(state)

    _ -> collect_response_loop(deadline_ms, client_ref, max_body_bytes, state)
  }
}

fn finalize_sync_state(
  state: ResponseState,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError) {
  case state.status, state.headers {
    Some(status), Some(headers) ->
      Ok(#(status, headers, bit_array.concat(list.reverse(state.chunks))))
    _, _ -> Error(Unexpected("Missing status or headers"))
  }
}

fn deadline_reached(deadline_ms: Int) -> Bool {
  ffi.now_ms() >= deadline_ms
}

fn hackney_error_to_http_error(err: hackney.Error) -> HttpError {
  case err {
    hackney.TimedOut -> Timeout
    hackney.ConnectionClosed(_) -> ConnectionError("Connection closed")
    hackney.NoStatusOrHeaders -> ConnectionError("No status or headers")
    hackney.InvalidUtf8Response -> InvalidUtf8Body
    hackney.Other(reason) -> Unexpected(string.inspect(reason))
    other -> Unexpected(string.inspect(other))
  }
}

/// Returns the managed-port host configured in `SadConfig`.
pub fn managed_port_host(config: types_config.SadConfig) -> String {
  let types_config.SadConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(managed_port_host: host, ..) = runner_cfg
  host
}

fn http_method_to_method(method: types_profile.HttpMethod) -> Method {
  case method {
    types_profile.HttpGet -> Get
    types_profile.HttpPost -> Post
    types_profile.HttpPut -> Put
    types_profile.HttpDelete -> Delete
  }
}

fn interpolate_url(
  template: String,
  input: types_input.SadInput,
  runner_host: Option(String),
  runner_port: Option(Int),
) -> Result(String, types_output.InteractionError) {
  let ctx =
    interpolator.build_context(
      input.params,
      input.input,
      input.context,
      runner_host,
      runner_port,
    )

  interpolator.interpolate_string(template, ctx)
}

/// Performs an optional HTTP health check for a continuous interface.
///
/// This performs a single attempt. When no health check is configured, it returns `Ok(Nil)`.
pub fn health_check(
  interface: types_profile.Interface,
  input: types_input.SadInput,
  runner_host: Option(String),
  runner_port: Option(Int),
  config: types_config.SadConfig,
) -> Result(Nil, types_output.InteractionError) {
  let trace_id = input.context.trace_id

  case interface {
    types_profile.RunnerInterface(_) -> Ok(Nil)

    types_profile.HttpInterface(
      base_url: base_url,
      headers: headers,
      health_check: health_check_opt,
      ..,
    ) ->
      case health_check_opt {
        None -> Ok(Nil)

        Some(types_profile.HealthCheck(
          path: path,
          method: http_method,
          expect_statuses: expect,
        )) -> {
          use url <- result.try(interpolate_url(
            base_url <> path,
            input,
            runner_host,
            runner_port,
          ))

          let types_config.SadConfig(timeouts: timeouts, limits: limits, ..) =
            config
          let types_config.SadTimeouts(health_check_timeout_ms: timeout_ms, ..) =
            timeouts
          let types_config.SadLimits(
            max_http_response_bytes: max_body_bytes,
            ..,
          ) = limits

          request_sync(
            http_method_to_method(http_method),
            url,
            headers,
            None,
            timeout_ms,
            max_body_bytes,
          )
          |> result.map_error(fn(err) {
            types_output.sad_error(
              trace_id,
              types_enums.InfraError,
              "Health check failed: " <> http_error_to_string(err),
            )
          })
          |> result.try(fn(resp) {
            case list.contains(expect, resp.status) {
              True -> Ok(Nil)
              False ->
                Error(types_output.sad_error(
                  trace_id,
                  types_enums.InfraError,
                  "Health check returned " <> int.to_string(resp.status),
                ))
            }
          })
        }
      }
  }
}

/// Builds managed-port environment variables for a runner.
///
/// This always injects `SAD_HOST` and `SAD_PORT` when a port is assigned.
/// It also injects `runner.runtime.{host_env_var,port_env_var}` when configured.
pub fn inject_managed_port_env(
  env: List(#(String, String)),
  trace_id: types_core.TraceId,
  config: types_config.SadConfig,
  runtime: types_runner.RuntimeConfig,
  assigned_port: Option(Int),
) -> Result(List(#(String, String)), types_output.InteractionError) {
  case assigned_port {
    None -> Ok(env)

    Some(port) -> {
      let host = managed_port_host(config)

      let types_runner.RuntimeConfig(
        mode: mode,
        port_env_var: port_env_var,
        host_env_var: host_env_var,
      ) = runtime

      let base_env =
        list.append(env, [
          #("SAD_HOST", host),
          #("SAD_PORT", int.to_string(port)),
        ])

      let base_env = case host_env_var {
        None -> base_env
        Some(name) -> list.append(base_env, [#(name, host)])
      }

      let base_env = case port_env_var {
        None -> base_env
        Some(name) -> list.append(base_env, [#(name, int.to_string(port))])
      }

      case mode {
        types_runner.ManagedPort ->
          port_check.check_available(host, port)
          |> result.map_error(fn(err) {
            types_output.sad_error(
              trace_id,
              types_enums.InfraError,
              "Managed port check failed: " <> string.inspect(err),
            )
          })
          |> result.map(fn(_) { base_env })

        types_runner.NoNetwork -> Ok(base_env)
      }
    }
  }
}

/// Rejects multipart when `streaming` is enabled.
pub fn ensure_multipart_allowed(
  trace_id: types_core.TraceId,
  streaming: Bool,
) -> Result(Nil, types_output.InteractionError) {
  case streaming {
    True ->
      Error(types_output.sad_error(
        trace_id,
        types_enums.BadRequest,
        "Multipart body is not supported for streaming in v0",
      ))
    False -> Ok(Nil)
  }
}

/// Builds and sends a multipart request using a single input file.
///
/// The file content is fetched from `file.url` and bounded by `limits.max_file_fetch_bytes`.
pub fn request_multipart(
  trace_id: types_core.TraceId,
  method: Method,
  url: String,
  headers: Dict(String, String),
  fields: Dict(String, String),
  file_field: String,
  file: types_input.FileRef,
  streaming: Bool,
  config: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(HttpResponse, types_output.InteractionError) {
  use _ <- result.try(ensure_multipart_allowed(trace_id, streaming))

  let types_config.SadConfig(limits: limits, ..) = config
  let types_config.SadLimits(
    max_file_fetch_bytes: max_file_bytes,
    max_http_response_bytes: max_resp_bytes,
    ..,
  ) = limits

  use file_bits <- result.try(
    fetch_bits(file.url, timeout_ms, max_file_bytes)
    |> result.map_error(fn(err) {
      types_output.sad_error(
        trace_id,
        types_enums.InfraError,
        "File fetch failed: " <> http_error_to_string(err),
      )
    }),
  )

  use #(boundary, body) <- result.try(
    build_multipart(fields, file_field, file, file_bits)
    |> result.map_error(fn(msg) {
      types_output.sad_error(trace_id, types_enums.InfraError, msg)
    }),
  )

  let headers =
    headers
    |> dict.insert("content-type", "multipart/form-data; boundary=" <> boundary)

  request_sync(method, url, headers, Some(body), timeout_ms, max_resp_bytes)
  |> result.map_error(fn(err) {
    types_output.sad_error(
      trace_id,
      types_enums.InfraError,
      http_error_to_string(err),
    )
  })
}

fn build_multipart(
  fields: Dict(String, String),
  file_field: String,
  file: types_input.FileRef,
  file_bits: BitArray,
) -> Result(#(String, String), String) {
  let boundary = "sad_boundary_" <> int.to_string(ffi.now_ms())

  use file_content <- result.try(
    bit_array.to_string(file_bits)
    |> result.map_error(fn(_) { "Fetched file is not UTF-8" }),
  )

  let fields_part =
    fields
    |> dict.to_list
    |> list.map(fn(pair) {
      "--"
      <> boundary
      <> "\r\n"
      <> "Content-Disposition: form-data; name=\""
      <> pair.0
      <> "\"\r\n\r\n"
      <> pair.1
      <> "\r\n"
    })
    |> string.join("")

  let types_input.FileRef(url: _, mime: mime, name: name, context: _) = file

  let file_part =
    "--"
    <> boundary
    <> "\r\n"
    <> "Content-Disposition: form-data; name=\""
    <> file_field
    <> "\"; filename=\""
    <> name
    <> "\"\r\n"
    <> "Content-Type: "
    <> mime
    <> "\r\n\r\n"
    <> file_content
    <> "\r\n"

  let end = "--" <> boundary <> "--\r\n"

  Ok(#(boundary, fields_part <> file_part <> end))
}

fn fetch_bits(
  url: String,
  timeout_ms: Int,
  max_body_bytes: Int,
) -> Result(BitArray, HttpError) {
  use req <- result.try(build_request(Get, url, dict.new(), None))

  let req =
    req
    |> request.map(bytes_tree.from_string)
    |> request.set_header("connection", "close")

  use client_ref <- result.try(start_async(req))
  let deadline_ms = ffi.now_ms() + int.max(timeout_ms, 1)

  use #(_status, _headers, body_bits) <- result.try(collect_response(
    deadline_ms,
    client_ref,
    max_body_bytes,
  ))

  hackney.close(client_ref)
  Ok(body_bits)
}

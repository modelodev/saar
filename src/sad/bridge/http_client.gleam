//// Bridge HTTP client (sync).
////
//// Mission: execute outbound HTTP requests for the bridge with explicit
//// timeouts and size limits.
////
//// Responsibilities:
//// - Build `gleam/http` requests for string and binary bodies.
//// - Execute requests via `httpp/hackney` in async mode.
//// - Enforce response size limits and request deadlines.
////
//// Non-responsibilities:
//// - SSE parsing/streaming semantics.
//// - Profile interpolation and higher-level error translation.
//// - Multipart body construction.
////
//// Relationships:
//// - Used by `sad/bridge/health_check` and `sad/bridge/multipart_proxy`.
//// - Uses `httpp/hackney` for the transport.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http.{type Method, Get}
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import httpp/hackney
import sad/ffi

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

/// Executes a synchronous HTTP request with a string body.
///
/// `max_body_bytes` is enforced for the response body.
pub fn request_sync_string(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
  timeout_ms: Int,
  max_body_bytes: Int,
) -> Result(HttpResponse, HttpError) {
  use req <- result.try(build_request_string(method, url, headers, body))

  use client_ref <- result.try(start_async(req))

  let deadline_ms = now_ms() + int.max(timeout_ms, 1)

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

/// Executes a synchronous HTTP request with a binary body.
///
/// `max_body_bytes` is enforced for the response body.
pub fn request_sync_bytes(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(bytes_tree.BytesTree),
  timeout_ms: Int,
  max_body_bytes: Int,
) -> Result(HttpResponse, HttpError) {
  use req <- result.try(build_request_bytes(method, url, headers, body))

  use client_ref <- result.try(start_async(req))

  let deadline_ms = now_ms() + int.max(timeout_ms, 1)

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

/// Fetches response bytes (body only) from a URL.
///
/// This is used when proxying URL-backed file references.
pub fn fetch_bits(
  url: String,
  timeout_ms: Int,
  max_body_bytes: Int,
) -> Result(BitArray, HttpError) {
  use req <- result.try(build_request_string(Get, url, dict.new(), None))

  use client_ref <- result.try(start_async(req))

  let deadline_ms = now_ms() + int.max(timeout_ms, 1)

  use #(_status, _headers, body_bits) <- result.try(collect_response(
    deadline_ms,
    client_ref,
    max_body_bytes,
  ))

  hackney.close(client_ref)
  Ok(body_bits)
}

fn build_request_string(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
) -> Result(request.Request(bytes_tree.BytesTree), HttpError) {
  request.to(url)
  |> result.map_error(fn(_) { InvalidUrl(url) })
  |> result.map(fn(req) {
    let req = request.set_method(req, method)

    let req =
      headers
      |> dict.to_list
      |> list.fold(req, fn(r, pair) { request.set_header(r, pair.0, pair.1) })

    let req = case body {
      None -> req
      Some(payload) -> request.set_body(req, payload)
    }

    req
    |> request.map(bytes_tree.from_string)
    |> request.set_header("connection", "close")
  })
}

fn build_request_bytes(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(bytes_tree.BytesTree),
) -> Result(request.Request(bytes_tree.BytesTree), HttpError) {
  request.to(url)
  |> result.map_error(fn(_) { InvalidUrl(url) })
  |> result.map(fn(req) {
    let req = request.set_method(req, method)

    let req =
      headers
      |> dict.to_list
      |> list.fold(req, fn(r, pair) { request.set_header(r, pair.0, pair.1) })

    let req = req |> request.map(fn(_) { bytes_tree.new() })

    let req = case body {
      None -> req
      Some(payload) -> request.set_body(req, payload)
    }

    request.set_header(req, "connection", "close")
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
  case now_ms() >= deadline_ms {
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
              handle_message(
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

fn handle_message(
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

    hackney.DoneStreaming -> finalize_state(state)

    _ -> collect_response_loop(deadline_ms, client_ref, max_body_bytes, state)
  }
}

fn finalize_state(
  state: ResponseState,
) -> Result(#(Int, List(#(String, String)), BitArray), HttpError) {
  case state.status, state.headers {
    Some(status), Some(headers) ->
      Ok(#(status, headers, bit_array.concat(list.reverse(state.chunks))))
    _, _ -> Error(Unexpected("Missing status or headers"))
  }
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

fn now_ms() -> Int {
  ffi.now_ms()
}

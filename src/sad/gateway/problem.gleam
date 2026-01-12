//// RFC 7807 Problem Details helpers.
////
//// Mission: produce consistent HTTP error responses for the gateway.
////
//// Responsibilities:
//// - Map `ErrorKind` to HTTP status/title/type.
//// - Map gateway-level failures (body too large, call timeouts) to HTTP.
//// - Include `extensions.kind` and `extensions.trace_id`.
////
//// Non-responsibilities:
//// - Performing IO.
//// - Logging.
////
//// Relationships:
//// - Used by `sad/gateway/http_server` and endpoint handlers.
//// - Mapping table is defined in `docs/arquitectura/protocolos.md`.

import gleam/bytes_tree
import gleam/http/response
import gleam/json
import mist
import sad/otp/safe_call
import sad/types/core as types_core
import sad/types/enums as types_enums

/// Builds a Problem Details response for a domain `ErrorKind`.
pub fn from_error_kind(
  kind: types_enums.ErrorKind,
  trace_id: types_core.TraceId,
  instance: String,
  detail: String,
) -> response.Response(mist.ResponseData) {
  let #(status, title, type_url) = error_kind_mapping(kind)

  build(
    status: status,
    title: title,
    type_url: type_url,
    detail: detail,
    instance: instance,
    kind: types_enums.error_kind_to_string(kind),
    trace_id: types_core.trace_id_to_string(trace_id),
  )
}

/// Maps a `safe_call.CallError` into a Problem Details response.
pub fn from_call_error(
  err: safe_call.CallError,
  trace_id: types_core.TraceId,
  instance: String,
) -> response.Response(mist.ResponseData) {
  let #(status, detail) = case err {
    safe_call.Disconnected -> #(503, "disconnected")
    safe_call.TimedOut -> #(504, "timeout")
  }

  build(
    status: status,
    title: http_title(status),
    type_url: "https://sad/errors/infra-error",
    detail: detail,
    instance: instance,
    kind: types_enums.error_kind_to_string(types_enums.InfraError),
    trace_id: types_core.trace_id_to_string(trace_id),
  )
}

/// Returns a 413 Problem Details response for oversized request bodies.
pub fn request_body_too_large(
  trace_id: types_core.TraceId,
  instance: String,
) -> response.Response(mist.ResponseData) {
  build(
    status: 413,
    title: "Payload Too Large",
    type_url: "https://sad/errors/invalid-request",
    detail: "request body too large",
    instance: instance,
    kind: types_enums.error_kind_to_string(types_enums.BadRequest),
    trace_id: types_core.trace_id_to_string(trace_id),
  )
}

/// Returns a 401 response for missing/invalid credentials.
pub fn unauthorized(
  trace_id: types_core.TraceId,
  instance: String,
  detail: String,
) -> response.Response(mist.ResponseData) {
  build(
    status: 401,
    title: "Unauthorized",
    type_url: "https://sad/errors/invalid-request",
    detail: detail,
    instance: instance,
    kind: types_enums.error_kind_to_string(types_enums.BadRequest),
    trace_id: types_core.trace_id_to_string(trace_id),
  )
}

/// Returns a 404 response.
pub fn not_found(
  trace_id: types_core.TraceId,
  instance: String,
) -> response.Response(mist.ResponseData) {
  build(
    status: 404,
    title: "Not Found",
    type_url: "https://sad/errors/invalid-request",
    detail: "not found",
    instance: instance,
    kind: types_enums.error_kind_to_string(types_enums.BadRequest),
    trace_id: types_core.trace_id_to_string(trace_id),
  )
}

fn error_kind_mapping(kind: types_enums.ErrorKind) -> #(Int, String, String) {
  case kind {
    types_enums.BadRequest -> #(
      400,
      "Bad Request",
      "https://sad/errors/invalid-request",
    )
    types_enums.AgentError -> #(
      422,
      "Unprocessable Entity",
      "https://sad/errors/upstream-error",
    )
    types_enums.InfraError -> #(
      500,
      "Internal Server Error",
      "https://sad/errors/infra-error",
    )
  }
}

fn http_title(status: Int) -> String {
  case status {
    503 -> "Service Unavailable"
    504 -> "Gateway Timeout"
    _ -> "Internal Server Error"
  }
}

fn build(
  status status: Int,
  title title: String,
  type_url type_url: String,
  detail detail: String,
  instance instance: String,
  kind kind: String,
  trace_id trace_id: String,
) -> response.Response(mist.ResponseData) {
  let body =
    json.object([
      #("type", json.string(type_url)),
      #("status", json.int(status)),
      #("title", json.string(title)),
      #("detail", json.string(detail)),
      #("instance", json.string(instance)),
      #(
        "extensions",
        json.object([
          #("kind", json.string(kind)),
          #("trace_id", json.string(trace_id)),
        ]),
      ),
    ])
    |> json.to_string
    |> bytes_tree.from_string

  response.new(status)
  |> response.set_header("content-type", "application/problem+json")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(mist.Bytes(body))
}

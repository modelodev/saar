//// Health endpoints for the gateway.
////
//// Mission: provide liveness and readiness endpoints for SAD.
////
//// Responsibilities:
//// - Implement `GET /health` (liveness).
//// - Implement `GET /health/ready` (readiness: requires profiles loaded).
////
//// Non-responsibilities:
//// - Authentication (these endpoints are public by design).
//// - Full operational metrics or tracing.
////
//// Relationships:
//// - Used by `sad/gateway/http_server`.
//// - Readiness depends on the `ProfilesActor` message protocol.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/json
import mist
import sad/core/messages
import sad/otp/safe_call

/// Returns a liveness response.
pub fn health() -> response.Response(mist.ResponseData) {
  let body =
    json.object([
      #("status", json.string("healthy")),
    ])
    |> json.to_string
    |> bytes_tree.from_string

  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body))
}

/// Returns readiness, requiring at least one profile loaded.
pub fn ready(
  profiles: process.Subject(messages.ProfilesMsg),
  timeout_ms: Int,
) -> response.Response(mist.ResponseData) {
  let status_code = case
    safe_call.call(profiles, timeout_ms, fn(reply_to) {
      messages.ListProfiles(reply_to)
    })
  {
    Ok(ids) ->
      case ids != [] {
        True -> 200
        False -> 503
      }

    Error(_) -> 503
  }

  let status = case status_code {
    200 -> "ready"
    _ -> "not_ready"
  }

  let body =
    json.object([
      #("status", json.string(status)),
    ])
    |> json.to_string
    |> bytes_tree.from_string

  response.new(status_code)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body))
}

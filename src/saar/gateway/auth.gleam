//// HTTP auth helpers for the gateway.
////
//// Mission: enforce the v0 API key authentication scheme for gateway endpoints.
////
//// Responsibilities:
//// - Parse and validate `Authorization: Bearer <token>`.
//// - Define the allowlist of unauthenticated endpoints.
////
//// Non-responsibilities:
//// - Building ProblemDetails responses (see `saar/gateway/problem`).
//// - Managing sessions, multiple keys, or OAuth.
////
//// Relationships:
//// - Used by `saar/gateway/http_server` request handlers.
//// - Uses `saar/types/core.SecretValue` as the configured API key.

import gleam/http/request
import gleam/result
import gleam/string
import saar/types/core as types_core

/// Errors produced while validating the Authorization header.
pub type AuthError {
  MissingAuthorization
  InvalidAuthorizationFormat
  InvalidToken
}

/// Returns `True` for endpoints that do not require authentication.
///
/// v0 allowlist:
/// - `GET /health`
/// - `GET /health/ready`
pub fn is_public_path(path: String) -> Bool {
  case path {
    "/health" | "/health/ready" -> True
    _ -> False
  }
}

/// Extracts the bearer token from an HTTP request, if present.
pub fn bearer_token(req: request.Request(body)) -> Result(String, AuthError) {
  case request.get_header(req, "authorization") {
    Error(_) -> Error(MissingAuthorization)
    Ok(value) ->
      value
      |> parse_bearer_header
      |> result.map_error(fn(_) { InvalidAuthorizationFormat })
  }
}

/// Validates that the request carries a correct `Bearer` token.
///
/// Returns `Ok(Nil)` when valid, or `Error(AuthError)` otherwise.
pub fn require_bearer(
  req: request.Request(body),
  api_key: types_core.SecretValue,
) -> Result(Nil, AuthError) {
  use token <- result.try(bearer_token(req))

  case token == types_core.secret_to_env_value(api_key) {
    True -> Ok(Nil)
    False -> Error(InvalidToken)
  }
}

fn parse_bearer_header(value: String) -> Result(String, Nil) {
  case string.split_once(value, on: "Bearer ") {
    Ok(#("", token)) ->
      case string.is_empty(token) {
        True -> Error(Nil)
        False -> Ok(token)
      }

    _ -> Error(Nil)
  }
}

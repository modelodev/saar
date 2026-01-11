//// Bridge HTTP utilities.
////
//// Mission: provide a stable bridge-facing API for outbound HTTP operations.
////
//// Responsibilities:
//// - Expose a small surface for sync HTTP requests, SSE upstream,
////   managed-port env injection, health checks, and multipart proxying.
//// - Keep transport/library details localized to bridge modules.
////
//// Non-responsibilities:
//// - Executing capabilities (bridge/orchestrator responsibility).
//// - Retrying for readiness (tests/orchestrator responsibility).
////
//// Relationships:
//// - Delegates to `sad/bridge/http_client`, `sad/bridge/sse_upstream`,
////   `sad/bridge/managed_port_env`, `sad/bridge/health_check`,
////   and `sad/bridge/multipart_proxy`.
//// - Used by `sad/bridge/runner` and integration tests.

import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/option.{type Option}
import sad/bridge/health_check as bridge_health
import sad/bridge/http_client
import sad/bridge/managed_port_env
import sad/bridge/multipart_proxy
import sad/bridge/sse_upstream
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/profile as types_profile
import sad/types/runner as types_runner

pub type HttpResponse =
  http_client.HttpResponse

pub type HttpError =
  http_client.HttpError

pub type SseConnection =
  sse_upstream.SseConnection

pub type SseEvent =
  sse_upstream.SseEvent

pub fn http_error_to_string(err: HttpError) -> String {
  http_client.http_error_to_string(err)
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
  http_client.request_sync_string(
    method,
    url,
    headers,
    body,
    timeout_ms,
    max_body_bytes,
  )
}

pub fn open_sse(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(String),
  initial_response_timeout_ms: Int,
) -> Result(SseConnection, HttpError) {
  sse_upstream.open_sse(method, url, headers, body, initial_response_timeout_ms)
}

pub fn sse_receive(conn: SseConnection, timeout_ms: Int) -> SseEvent {
  sse_upstream.sse_receive(conn, timeout_ms)
}

pub fn close_sse(conn: SseConnection) -> Nil {
  sse_upstream.close_sse(conn)
}

pub fn read_sse_until_result(
  conn: SseConnection,
  trace_id: types_core.TraceId,
  max_event_bytes: Int,
  timeout_ms: Int,
) -> Result(types_runner.RunnerResponse, types_output.InteractionError) {
  sse_upstream.read_sse_until_result(
    conn,
    trace_id,
    max_event_bytes,
    timeout_ms,
  )
}

pub fn managed_port_host(config: types_config.SadConfig) -> String {
  managed_port_env.managed_port_host(config)
}

pub fn inject_managed_port_env(
  env: List(#(String, String)),
  trace_id: types_core.TraceId,
  config: types_config.SadConfig,
  runtime: types_runner.RuntimeConfig,
  assigned_port: Option(Int),
) -> Result(List(#(String, String)), types_output.InteractionError) {
  managed_port_env.inject_managed_port_env(
    env,
    trace_id,
    config,
    runtime,
    assigned_port,
  )
}

pub fn health_check(
  interface: types_profile.Interface,
  input: types_input.SadInput,
  runner_host: Option(String),
  runner_port: Option(Int),
  config: types_config.SadConfig,
) -> Result(Nil, types_output.InteractionError) {
  bridge_health.health_check(interface, input, runner_host, runner_port, config)
}

pub fn ensure_multipart_allowed(
  trace_id: types_core.TraceId,
  streaming: Bool,
) -> Result(Nil, types_output.InteractionError) {
  multipart_proxy.ensure_multipart_allowed(trace_id, streaming)
}

pub fn request_multipart_files(
  trace_id: types_core.TraceId,
  method: Method,
  url: String,
  headers: Dict(String, String),
  fields: Dict(String, String),
  file_field: String,
  files: List(types_input.FileRef),
  streaming: Bool,
  config: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(List(HttpResponse), types_output.InteractionError) {
  multipart_proxy.request_multipart_files(
    trace_id,
    method,
    url,
    headers,
    fields,
    file_field,
    files,
    streaming,
    config,
    timeout_ms,
  )
}

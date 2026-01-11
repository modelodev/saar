//// HTTP health checks for continuous runners.
////
//// Mission: perform an optional health check defined by an HTTP interface.
////
//// Responsibilities:
//// - Interpolate the health-check URL using the bridge interpolator.
//// - Perform a single HTTP request using configured timeouts/limits.
//// - Translate HTTP client failures into `InteractionError(InfraError, ...)`.
////
//// Non-responsibilities:
//// - Waiting for readiness with sleeps or retries.
//// - Starting/stopping runner processes.
////
//// Relationships:
//// - Uses `sad/bridge/http_client` for HTTP.
//// - Uses `sad/bridge/interpolator` for strict templating.

import gleam/http.{type Method, Delete, Get, Post, Put}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sad/bridge/http_client
import sad/bridge/interpolator
import sad/types/config as types_config
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/profile as types_profile

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
          method: method,
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

          http_client.request_sync_string(
            http_method_to_method(method),
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
              "Health check failed: " <> http_client.http_error_to_string(err),
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

fn http_method_to_method(method: types_profile.HttpMethod) -> Method {
  case method {
    types_profile.HttpGet -> Get
    types_profile.HttpPost -> Post
    types_profile.HttpPut -> Put
    types_profile.HttpDelete -> Delete
  }
}

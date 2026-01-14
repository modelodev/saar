//// UI HTTP proxy endpoint.
////
//// Mission: proxy HTTP requests to an agent UI server.
////
//// Responsibilities:
//// - Forward HTTP requests to the agent `HttpInterface.base_url` using
////   `{{runner.host}}` and `{{runner.port}}` interpolation.
//// - Reject WebSocket upgrade attempts.
//// - Preserve upstream status code and content type.
////
//// Non-responsibilities:
//// - CORS.
//// - WebSocket proxying.
////
//// Relationships:
//// - Routed by `sad/gateway/http_server`.
//// - Uses `sad/bridge/http_client` for upstream requests.

import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import mist
import sad/bridge/http_client
import sad/bridge/interpolator
import sad/bridge/managed_port_env
import sad/core/agent
import sad/core/boundary_call
import sad/core/messages
import sad/gateway/problem
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/profile as types_profile

pub type Deps {
  Deps(
    registry: process.Subject(messages.RegistryMsg),
    profiles: process.Subject(messages.ProfilesMsg),
  )
}

/// Routes a request under `/agents/:instance_id/ui/*`.
///
/// `/ui/:instance_id/*` is accepted as a legacy alias for tests.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case is_websocket_upgrade(req) {
    True ->
      problem.bad_request_with_code(
        trace_id,
        req.path,
        "websocket upgrade not supported",
        "websocket_not_supported",
      )

    False -> route_http(req, cfg, deps, trace_id)
  }
}

fn route_http(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let path_only = path_without_query(req.path)

  case path_segments(path_only) {
    ["ui", instance_raw, ..rest] ->
      proxy_to_instance(req, cfg, deps, trace_id, instance_raw, rest)

    ["agents", instance_raw, "ui", ..rest] ->
      proxy_to_instance(req, cfg, deps, trace_id, instance_raw, rest)

    _ -> problem.not_found(trace_id, req.path)
  }
}

fn proxy_to_instance(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
  rest: List(String),
) -> response.Response(mist.ResponseData) {
  case is_path_traversal(req.path, rest) {
    True ->
      problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        req.path,
        "path traversal not allowed",
      )

    False ->
      case types_core.instance_id(instance_raw) {
        Error(_) ->
          problem.from_error_kind(
            types_enums.BadRequest,
            trace_id,
            req.path,
            "invalid instance id",
          )

        Ok(instance_id) -> {
          let Deps(registry: registry, profiles: profiles) = deps

          let found =
            boundary_call.call(registry, registry_timeout_ms(cfg), fn(reply_to) {
              messages.LookupByInstanceId(instance_id, reply_to)
            })

          case found {
            Error(call_err) ->
              problem.from_call_error(call_err, trace_id, req.path)
            Ok(option.None) -> problem.not_found(trace_id, req.path)

            Ok(option.Some(agent_ref)) ->
              proxy_via_profile(
                req,
                cfg,
                profiles,
                trace_id,
                agent_ref,
                instance_id,
                rest,
              )
          }
        }
      }
  }
}

fn proxy_via_profile(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  profiles: process.Subject(messages.ProfilesMsg),
  trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
  instance_id: types_core.InstanceId,
  rest: List(String),
) -> response.Response(mist.ResponseData) {
  case agent.status(agent_ref, status_timeout_ms(cfg)) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)

    Ok(status) -> {
      let profile_id = status.profile_id

      case status.assigned_port {
        option.None ->
          problem.infra_error_with_status(
            502,
            trace_id,
            req.path,
            "upstream unavailable",
          )

        option.Some(runner_port) -> {
          let profile_out =
            boundary_call.call(profiles, call_timeout_ms(cfg), fn(reply_to) {
              messages.GetProfile(profile_id, reply_to)
            })

          case profile_out {
            Error(call_err) ->
              problem.from_call_error(call_err, trace_id, req.path)
            Ok(option.None) -> problem.not_found(trace_id, req.path)

            Ok(option.Some(profile)) ->
              proxy_to_interface(
                req,
                cfg,
                trace_id,
                profile,
                runner_port,
                instance_id,
                profile_id,
                rest,
              )
          }
        }
      }
    }
  }
}

fn proxy_to_interface(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  trace_id: types_core.TraceId,
  profile: types_profile.Profile,
  runner_port: Int,
  instance_id: types_core.InstanceId,
  profile_id: types_core.ProfileId,
  rest: List(String),
) -> response.Response(mist.ResponseData) {
  case profile.interface {
    types_profile.RunnerInterface(_) ->
      problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        req.path,
        "profile is not http-capable",
      )

    types_profile.HttpInterface(base_url: base_url, headers: headers, ..) -> {
      let ctx =
        interpolator.build_context(
          dict.new(),
          types_input.PayloadChat([], dict.new()),
          types_input.RequestContext(trace_id: trace_id, extra: dict.new()),
          option.Some(managed_port_env.managed_port_host(cfg)),
          option.Some(runner_port),
        )

      case interpolator.interpolate_string(base_url, ctx) {
        Error(err) ->
          problem.from_error_kind(
            types_enums.BadRequest,
            trace_id,
            req.path,
            "invalid base_url: " <> err.message,
          )

        Ok(upstream_base) ->
          proxy_http(
            req,
            cfg,
            trace_id,
            upstream_base,
            headers,
            instance_id,
            profile_id,
            rest,
          )
      }
    }
  }
}

fn proxy_http(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  trace_id: types_core.TraceId,
  base_url: String,
  interface_headers: dict.Dict(String, String),
  instance_id: types_core.InstanceId,
  profile_id: types_core.ProfileId,
  rest: List(String),
) -> response.Response(mist.ResponseData) {
  let upstream_path = "/" <> string.join(rest, with: "/")

  let query = case req.query {
    option.Some(q) -> "?" <> q
    option.None -> ""
  }

  let url = base_url <> upstream_path <> query

  let max_body = max_request_body_bytes(cfg)

  let body_out = case req.method {
    http.Get | http.Head -> Ok(option.None)
    _ ->
      mist.read_body(req, max_body)
      |> result.map(fn(req_with_body) {
        option.Some(bytes_tree.from_bit_array(req_with_body.body))
      })
  }

  case body_out {
    Error(mist.ExcessBody) -> problem.request_body_too_large(trace_id, req.path)

    Error(_) ->
      problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        req.path,
        "malformed body",
      )

    Ok(body) -> {
      let headers =
        build_upstream_headers(req, interface_headers, instance_id, profile_id)

      let max_resp = max_http_response_bytes(cfg)

      case
        http_client.request_sync_bits(
          req.method,
          url,
          headers,
          body,
          call_timeout_ms(cfg),
          max_resp,
        )
      {
        Error(_) ->
          problem.infra_error_with_status(
            502,
            trace_id,
            req.path,
            "upstream error",
          )

        Ok(http_client.HttpResponseBits(
          status: status,
          headers: upstream_headers,
          body: bits,
        )) -> {
          let content_type =
            find_header(upstream_headers, "content-type")
            |> option.unwrap("application/octet-stream")

          response.new(status)
          |> response.set_header("content-type", content_type)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bits)))
        }
      }
    }
  }
}

fn build_upstream_headers(
  req: request.Request(body),
  base: dict.Dict(String, String),
  instance_id: types_core.InstanceId,
  profile_id: types_core.ProfileId,
) -> dict.Dict(String, String) {
  let headers =
    base
    |> add_if_present(req, "accept")
    |> add_if_present(req, "accept-language")
    |> add_if_present(req, "user-agent")
    |> add_if_present(req, "content-type")

  let headers =
    headers
    |> dict.insert(
      "x-sad-instance-id",
      types_core.instance_id_to_string(instance_id),
    )
    |> dict.insert(
      "x-sad-profile-id",
      types_core.profile_id_to_string(profile_id),
    )
    |> dict.insert("x-forwarded-proto", "http")

  let headers = case request.get_header(req, "host") {
    Ok(host) -> dict.insert(headers, "x-forwarded-host", host)
    Error(_) -> headers
  }

  let forwarded_for = case request.get_header(req, "x-forwarded-for") {
    Ok(value) -> value
    Error(_) -> "127.0.0.1"
  }

  dict.insert(headers, "x-forwarded-for", forwarded_for)
}

fn add_if_present(
  headers: dict.Dict(String, String),
  req: request.Request(body),
  key: String,
) -> dict.Dict(String, String) {
  case request.get_header(req, key) {
    Ok(value) -> dict.insert(headers, key, value)
    Error(_) -> headers
  }
}

fn is_path_traversal(path: String, segments: List(String)) -> Bool {
  let lower = string.lowercase(path)

  string.contains(lower, "%2e%2e")
  || string.contains(lower, "/../")
  || string.ends_with(lower, "/..")
  || list.any(segments, fn(seg) { seg == ".." })
}

fn path_without_query(path: String) -> String {
  case string.split_once(path, on: "?") {
    Ok(#(p, _q)) -> p
    Error(_) -> path
  }
}

fn path_segments(path: String) -> List(String) {
  let parts = string.split(path, "/")
  list.filter(parts, fn(seg) { seg != "" })
}

fn find_header(
  headers: List(#(String, String)),
  key: String,
) -> option.Option(String) {
  headers
  |> list.fold(option.None, fn(acc, pair) {
    case acc {
      option.Some(_) -> acc
      option.None ->
        case string.lowercase(pair.0) == key {
          True -> option.Some(pair.1)
          False -> option.None
        }
    }
  })
}

fn is_websocket_upgrade(req: request.Request(body)) -> Bool {
  let upgrade =
    request.get_header(req, "upgrade")
    |> result.unwrap("")
    |> string.lowercase

  let connection =
    request.get_header(req, "connection")
    |> result.unwrap("")
    |> string.lowercase

  upgrade == "websocket" || string.contains(connection, "upgrade")
}

fn call_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(call_timeout_ms: ms, ..) = timeouts
  ms
}

fn status_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(status_timeout_ms: ms, ..) = timeouts
  ms
}

fn registry_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(registry_timeout_ms: ms, ..) = timeouts
  ms
}

fn max_request_body_bytes(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(limits: limits, ..) = cfg
  let types_config.SadLimits(max_request_body_bytes: bytes, ..) = limits
  bytes
}

fn max_http_response_bytes(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(limits: limits, ..) = cfg
  let types_config.SadLimits(max_http_response_bytes: bytes, ..) = limits
  bytes
}

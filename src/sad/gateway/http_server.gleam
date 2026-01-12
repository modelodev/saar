//// HTTP gateway server.
////
//// Mission: expose the SAD HTTP gateway endpoints using `mist`.
////
//// Responsibilities:
//// - Start an HTTP server bound to `server.host`/`server.port`.
//// - Route requests to `/health`, `/health/ready`, and `/sys/*`.
//// - Enforce v0 API key authentication (Bearer) outside health endpoints.
////
//// Non-responsibilities:
//// - Implementing the core actor logic (handled by `sad/core/*`).
//// - Owning gateway business state; this module is pure routing.
////
//// Relationships:
//// - Started by `sad/core/root_supervisor` as the last RestForOne child.
//// - Calls into `sad/gateway/sys_api` and `sad/gateway/health`.

import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/result
import gleam/string
import mist
import sad/core/messages
import sad/gateway/auth
import sad/gateway/health
import sad/gateway/problem
import sad/gateway/sys_api
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import youid/uuid

pub fn start(
  config: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
  profiles: process.Subject(messages.ProfilesMsg),
  agent_manager: process.Subject(messages.AgentManagerMsg),
) -> actor.StartResult(Nil) {
  let types_config.SadConfig(server_host: host, server_port: port, ..) = config

  let deps =
    sys_api.Deps(
      registry: registry,
      profiles: profiles,
      agent_manager: agent_manager,
    )

  let handler = fn(req) { handle_request(req, config, deps, profiles) }

  mist.new(handler)
  |> mist.bind(host)
  |> mist.port(port)
  |> mist.start
  |> result.map(fn(started) { actor.Started(pid: started.pid, data: Nil) })
}

fn handle_request(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: sys_api.Deps,
  profiles: process.Subject(messages.ProfilesMsg),
) -> response.Response(mist.ResponseData) {
  let trace_id = request_trace_id()

  case req.path, req.method {
    "/health", _ -> health.health()

    "/health/ready", _ -> {
      let timeout_ms = call_timeout_ms(cfg)
      health.ready(profiles, timeout_ms)
    }

    _, _ -> {
      let types_config.SadConfig(api_key: api_key, ..) = cfg

      case auth.require_bearer(req, api_key) {
        Ok(Nil) ->
          case string.starts_with(req.path, "/sys") {
            True -> sys_api.handle(req, cfg, deps, trace_id)
            False -> problem.not_found(trace_id, req.path)
          }

        Error(auth.MissingAuthorization) ->
          problem.unauthorized(trace_id, req.path, "missing authorization")

        Error(auth.InvalidToken) ->
          problem.unauthorized(trace_id, req.path, "invalid token")

        Error(auth.InvalidAuthorizationFormat) ->
          problem.from_error_kind(
            types_enums.BadRequest,
            trace_id,
            req.path,
            "invalid authorization header",
          )
      }
    }
  }
}

fn request_trace_id() -> types_core.TraceId {
  types_core.trace_id(uuid.v7_string())
}

fn call_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(call_timeout_ms: ms, ..) = timeouts
  ms
}

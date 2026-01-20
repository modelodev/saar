//// HTTP gateway server.
////
//// Mission: expose the SAAR HTTP gateway endpoints using `mist`.
////
//// Responsibilities:
//// - Start an HTTP server bound to `server.host`/`server.port`.
//// - Route requests to `/health`, `/health/ready`, `/sys/*`, `/agents/*`, and `/instances/*`.
//// - Enforce v0 API key authentication (Bearer) outside health endpoints.
////
//// Non-responsibilities:
//// - Implementing the core actor logic (handled by `saar/core/*`).
//// - Owning gateway business state; this module is pure routing.
////
//// Relationships:
//// - Started by `saar/core/root_supervisor` as the last RestForOne child.
//// - Calls into `saar/gateway/sys_api` and `saar/gateway/health`.

import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/result
import gleam/string
import mist
import saar/core/artifact_registry_protocol
import saar/core/messages
import saar/core/task_store_protocol
import saar/gateway/a2a_api
import saar/gateway/agents_api
import saar/gateway/artifacts_api
import saar/gateway/auth
import saar/gateway/health
import saar/gateway/problem
import saar/gateway/shutdown as gateway_shutdown
import saar/gateway/sys_api
import saar/gateway/tasks_api
import saar/gateway/ui_proxy_api
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import youid/uuid

pub fn start(
  config: types_config.SaarConfig,
  registry: process.Subject(messages.RegistryMsg),
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  profiles: process.Subject(messages.ProfilesMsg),
  task_store: process.Subject(task_store_protocol.TaskStoreMsg),
  agent_manager: process.Subject(messages.AgentManagerMsg),
  shutdown: process.Subject(gateway_shutdown.Msg),
) -> actor.StartResult(Nil) {
  let types_config.SaarConfig(server_host: host, server_port: port, ..) = config

  let sys_deps =
    sys_api.Deps(
      registry: registry,
      profiles: profiles,
      agent_manager: agent_manager,
    )

  let agents_deps = agents_api.Deps(registry: registry, task_store: task_store)
  let a2a_deps = a2a_api.Deps(registry: registry, task_store: task_store)
  let artifacts_deps = artifacts_api.Deps(artifact_registry: artifact_registry)
  let tasks_deps = tasks_api.Deps(registry: registry, task_store: task_store)
  let ui_deps = ui_proxy_api.Deps(registry: registry, profiles: profiles)

  let handler = fn(req) {
    handle_request(
      req,
      config,
      sys_deps,
      agents_deps,
      a2a_deps,
      artifacts_deps,
      tasks_deps,
      ui_deps,
      profiles,
      shutdown,
    )
  }

  mist.new(handler)
  |> mist.bind(host)
  |> mist.port(port)
  |> mist.start
  |> result.map(fn(started) { actor.Started(pid: started.pid, data: Nil) })
}

fn handle_request(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  sys_deps: sys_api.Deps,
  agents_deps: agents_api.Deps,
  a2a_deps: a2a_api.Deps,
  artifacts_deps: artifacts_api.Deps,
  tasks_deps: tasks_api.Deps,
  ui_deps: ui_proxy_api.Deps,
  profiles: process.Subject(messages.ProfilesMsg),
  shutdown: process.Subject(gateway_shutdown.Msg),
) -> response.Response(mist.ResponseData) {
  let trace_id = request_trace_id()

  case gateway_shutdown.enter_request(shutdown, 50) {
    False ->
      problem.infra_error_with_code(
        503,
        trace_id,
        req.path,
        "shutting down",
        "shutting_down",
      )

    True -> {
      let resp =
        route_request(
          req,
          cfg,
          sys_deps,
          agents_deps,
          a2a_deps,
          artifacts_deps,
          tasks_deps,
          ui_deps,
          profiles,
          trace_id,
        )

      gateway_shutdown.leave_request(shutdown)
      resp
    }
  }
}

fn route_request(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  sys_deps: sys_api.Deps,
  agents_deps: agents_api.Deps,
  a2a_deps: a2a_api.Deps,
  artifacts_deps: artifacts_api.Deps,
  tasks_deps: tasks_api.Deps,
  ui_deps: ui_proxy_api.Deps,
  profiles: process.Subject(messages.ProfilesMsg),
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case auth.is_public_path(req.path) {
    True ->
      case req.path {
        "/health" -> health.health()

        "/health/ready" -> {
          let timeout_ms = call_timeout_ms(cfg)
          health.ready(profiles, timeout_ms)
        }

        _ -> problem.not_found(trace_id, req.path)
      }

    False -> {
      let types_config.SaarConfig(api_key: api_key, ..) = cfg

      case auth.require_bearer(req, api_key) {
        Ok(Nil) ->
          case string.starts_with(req.path, "/sys") {
            True -> sys_api.handle(req, cfg, sys_deps, trace_id)
            False ->
              case string.starts_with(req.path, "/instances") {
                True -> a2a_api.handle(req, cfg, a2a_deps, trace_id)

                False ->
                  case string.starts_with(req.path, "/agents") {
                    True ->
                      case request.path_segments(req) {
                        ["agents", _, "ui", ..] ->
                          ui_proxy_api.handle(req, cfg, ui_deps, trace_id)

                        _ ->
                          case string.contains(req.path, "/ui/") {
                            True ->
                              ui_proxy_api.handle(req, cfg, ui_deps, trace_id)
                            False ->
                              agents_api.handle(req, cfg, agents_deps, trace_id)
                          }
                      }

                    False ->
                      case string.starts_with(req.path, "/artifacts") {
                        True ->
                          artifacts_api.handle(
                            req,
                            cfg,
                            artifacts_deps,
                            trace_id,
                          )
                        False ->
                          case string.starts_with(req.path, "/tasks") {
                            True ->
                              tasks_api.handle(req, cfg, tasks_deps, trace_id)
                            False ->
                              case string.starts_with(req.path, "/ui") {
                                True ->
                                  ui_proxy_api.handle(
                                    req,
                                    cfg,
                                    ui_deps,
                                    trace_id,
                                  )
                                False -> problem.not_found(trace_id, req.path)
                              }
                          }
                      }
                  }
              }
          }

        Error(auth.MissingAuthorization) ->
          case string.starts_with(req.path, "/instances") {
            True -> problem.unauthorized_a2a(trace_id, "missing authorization")
            False ->
              problem.unauthorized(trace_id, req.path, "missing authorization")
          }

        Error(auth.InvalidToken) ->
          case string.starts_with(req.path, "/instances") {
            True -> problem.unauthorized_a2a(trace_id, "invalid token")
            False -> problem.unauthorized(trace_id, req.path, "invalid token")
          }

        Error(auth.InvalidAuthorizationFormat) ->
          case string.starts_with(req.path, "/instances") {
            True ->
              problem.from_error_kind_a2a(
                types_enums.BadRequest,
                trace_id,
                "invalid authorization header",
              )

            False ->
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
}

fn request_trace_id() -> types_core.TraceId {
  types_core.trace_id(uuid.v7_string())
}

fn call_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(call_timeout_ms: ms, ..) = timeouts
  ms
}

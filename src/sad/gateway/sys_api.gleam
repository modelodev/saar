//// `/sys` HTTP API.
////
//// Mission: expose orchestration endpoints for managing instances and profiles.
////
//// Responsibilities:
//// - Implement `/sys/agents` management endpoints.
//// - Implement `/sys/reload-profiles` and `/sys/profiles`.
//// - Provide per-instance `a2a_base_url` construction.
////
//// Non-responsibilities:
//// - Native `/agents` interaction endpoints (future sprints).
//// - Artifact/UI proxies (future sprints).
////
//// Relationships:
//// - Bridges HTTP requests to core actors via `sad/otp/safe_call`.
//// - Uses `sad/gateway/problem` for RFC7807 responses.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/yielder
import mist
import sad/core/agent
import sad/core/messages
import sad/decoders
import sad/gateway/lookup
import sad/gateway/lookup_http
import sad/gateway/problem
import sad/gateway/request_url
import sad/otp/safe_call
import sad/profiles_sources
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/log as types_log
import sad/types/profile as types_profile

pub type Deps {
  Deps(
    registry: process.Subject(messages.RegistryMsg),
    profiles: process.Subject(messages.ProfilesMsg),
    agent_manager: process.Subject(messages.AgentManagerMsg),
  )
}

/// Routes a request under `/sys`.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let segments = request.path_segments(req)

  case segments {
    ["sys", "agents"] -> handle_agents_collection(req, cfg, deps, trace_id)

    ["sys", "agents", instance_id, "status"] ->
      handle_agent_status(req, cfg, deps, trace_id, instance_id)

    ["sys", "agents", instance_id, "stop"] ->
      handle_agent_stop(req, cfg, deps, trace_id, instance_id)

    ["sys", "agents", instance_id, "start"] ->
      handle_agent_start(req, cfg, deps, trace_id, instance_id)

    ["sys", "agents", instance_id, "logs", "stream"] ->
      handle_agent_logs_stream(req, cfg, deps, trace_id, instance_id)

    ["sys", "agents", instance_id] ->
      handle_agent_item(req, cfg, deps, trace_id, instance_id)

    ["sys", "reload-profiles"] ->
      handle_reload_profiles(req, cfg, deps, trace_id)
    ["sys", "profiles"] -> handle_sys_profiles(req, cfg, deps, trace_id)

    _ -> problem.not_found(trace_id, req.path)
  }
}

fn handle_agents_collection(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get -> list_agents(req, cfg, deps, trace_id)
    http.Post -> create_agent(req, cfg, deps, trace_id)
    _ -> empty_response(405)
  }
}

fn create_agent(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let max_body = max_request_body_bytes(cfg)
  let path = req.path

  case mist.read_body(req, max_body) {
    Error(mist.ExcessBody) -> problem.request_body_too_large(trace_id, path)

    Error(_) ->
      problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        path,
        "malformed body",
      )

    Ok(req_with_body) -> {
      let body =
        bit_array.to_string(req_with_body.body)
        |> result.unwrap("")

      case decode_create_agent(body) {
        Error(message) ->
          problem.from_error_kind(
            types_enums.BadRequest,
            trace_id,
            path,
            "invalid json: " <> message,
          )

        Ok(CreateAgentReq(
          profile_id: profile_id,
          instance_id: instance_id,
          init_params: init_params,
        )) -> {
          let Deps(agent_manager: manager, ..) = deps

          let out =
            safe_call.call_unwrap_result(
              manager,
              call_timeout_ms(cfg),
              fn(reply_to) {
                messages.Cmd(messages.CreateAgent(
                  types_core.profile_id(profile_id),
                  instance_id,
                  init_params,
                  reply_to,
                ))
              },
            )

          case out {
            Ok(agent_ref) -> {
              let status =
                agent.status(agent_ref, status_timeout_ms(cfg))
                |> result.unwrap(initial_status(profile_id, instance_id))

              json_response(
                201,
                json.object([
                  #("profile_id", json.string(profile_id)),
                  #(
                    "instance_id",
                    json.string(types_core.instance_id_to_string(instance_id)),
                  ),
                  #("a2a_base_url", json.string(a2a_base_url(req, instance_id))),
                  #("status", encode_status(status)),
                ]),
              )
            }

            Error(safe_call.CallFailed(call_err)) ->
              problem.from_call_error(call_err, trace_id, path)

            Error(safe_call.ActorError(err)) ->
              start_error_to_response(req, trace_id, err)
          }
        }
      }
    }
  }
}

type CreateAgentReq {
  CreateAgentReq(
    profile_id: String,
    instance_id: types_core.InstanceId,
    init_params: Dict(String, types_core.Value),
  )
}

fn decode_create_agent(body: String) -> Result(CreateAgentReq, String) {
  use value <- result.try(
    json.parse(body, decode.dynamic)
    |> result.map_error(string.inspect),
  )

  let decoder = {
    use profile_id <- decode.field("profile_id", decode.string)
    use instance_raw <- decode.field("instance_id", decode.string)
    use init_params_raw <- decode.optional_field(
      "init_params",
      dict.new(),
      decode.dict(decode.string, decode.dynamic),
    )

    decode.success(#(profile_id, instance_raw, init_params_raw))
  }

  use decoded <- result.try(
    decode.run(value, decoder)
    |> result.map_error(string.inspect),
  )

  let #(profile_id, instance_raw, init_params_raw) = decoded

  use init_params <- result.try(decode_init_params(init_params_raw))

  case types_core.instance_id(instance_raw) {
    Ok(id) ->
      Ok(CreateAgentReq(
        profile_id: profile_id,
        instance_id: id,
        init_params: init_params,
      ))
    Error(err) ->
      Error(
        "invalid instance_id: " <> types_core.instance_id_error_to_string(err),
      )
  }
}

fn decode_init_params(
  values: Dict(String, Dynamic),
) -> Result(Dict(String, types_core.Value), String) {
  values
  |> dict.fold(Ok(dict.new()), fn(acc, key, value) {
    use acc <- result.try(acc)

    case decoders.decode_scalar_value(value) {
      Ok(v) -> Ok(dict.insert(acc, key, v))
      Error(_) ->
        Error(
          "invalid init_params."
          <> key
          <> ": expected scalar, got "
          <> decoders.describe_dynamic_type(value),
        )
    }
  })
}

fn list_agents(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let Deps(agent_manager: manager, ..) = deps

  case
    safe_call.call(manager, registry_timeout_ms(cfg), fn(reply_to) {
      messages.Cmd(messages.ListAgents(reply_to))
    })
  {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)

    Ok(items) -> {
      let agents =
        items |> list.map(fn(item) { encode_instance_summary(req, item) })

      json_response(
        200,
        json.object([
          #("agents", json.array(agents, fn(x) { x })),
        ]),
      )
    }
  }
}

fn handle_agent_status(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case parse_instance_id_or_400(instance_raw, trace_id, req.path) {
    Error(resp) -> resp

    Ok(instance_id) -> {
      let Deps(registry: registry, ..) = deps

      case
        safe_call.call(registry, registry_timeout_ms(cfg), fn(reply_to) {
          messages.LookupStatusByInstanceId(instance_id, reply_to)
        })
      {
        Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)
        Ok(None) -> problem.not_found(trace_id, req.path)
        Ok(Some(status)) -> json_response(200, encode_status(status))
      }
    }
  }
}

fn handle_agent_stop(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_instance_id_or_400(instance_raw, trace_id, req.path) {
        Error(resp) -> resp

        Ok(instance_id) -> {
          let Deps(agent_manager: manager, ..) = deps

          case
            safe_call.call_unwrap_result(
              manager,
              call_timeout_ms(cfg),
              fn(reply_to) {
                messages.Cmd(messages.StopAgent(instance_id, reply_to))
              },
            )
          {
            Ok(_) -> accepted_json(instance_id)

            Error(safe_call.CallFailed(call_err)) ->
              problem.from_call_error(call_err, trace_id, req.path)

            Error(safe_call.ActorError(_)) ->
              problem.from_error_kind(
                types_enums.InfraError,
                trace_id,
                req.path,
                "stop failed",
              )
          }
        }
      }

    _ -> empty_response(405)
  }
}

fn handle_agent_start(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_instance_id_or_400(instance_raw, trace_id, req.path) {
        Error(resp) -> resp

        Ok(instance_id) -> {
          let Deps(agent_manager: manager, ..) = deps

          case
            safe_call.call_unwrap_result(
              manager,
              call_timeout_ms(cfg),
              fn(reply_to) {
                messages.Cmd(messages.StartExistingAgent(instance_id, reply_to))
              },
            )
          {
            Ok(_) -> accepted_json(instance_id)

            Error(safe_call.CallFailed(call_err)) ->
              problem.from_call_error(call_err, trace_id, req.path)

            Error(safe_call.ActorError(_)) ->
              problem.from_error_kind(
                types_enums.InfraError,
                trace_id,
                req.path,
                "start failed",
              )
          }
        }
      }

    _ -> empty_response(405)
  }
}

fn handle_agent_item(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Delete ->
      case parse_instance_id_or_400(instance_raw, trace_id, req.path) {
        Error(resp) -> resp

        Ok(instance_id) -> {
          let Deps(agent_manager: manager, ..) = deps

          case
            safe_call.call_unwrap_result(
              manager,
              call_timeout_ms(cfg),
              fn(reply_to) {
                messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
              },
            )
          {
            Ok(_) -> accepted_json(instance_id)

            Error(safe_call.CallFailed(call_err)) ->
              problem.from_call_error(call_err, trace_id, req.path)

            Error(safe_call.ActorError(_)) ->
              problem.from_error_kind(
                types_enums.InfraError,
                trace_id,
                req.path,
                "delete failed",
              )
          }
        }
      }

    _ -> problem.not_found(trace_id, req.path)
  }
}

fn handle_agent_logs_stream(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get ->
      case parse_instance_id_or_400(instance_raw, trace_id, req.path) {
        Error(resp) -> resp

        Ok(instance_id) -> {
          let Deps(registry: registry, ..) = deps

          lookup_http.with_agent_ref(
            registry,
            registry_timeout_ms(cfg),
            trace_id,
            req.path,
            instance_id,
            fn(agent_ref) { logs_stream_response(cfg, agent_ref) },
          )
        }
      }

    _ -> empty_response(405)
  }
}

fn logs_stream_response(
  cfg: types_config.SadConfig,
  agent_ref: agent.AgentRef,
) -> response.Response(mist.ResponseData) {
  let keep_alive_ms = sse_keep_alive_interval_ms(cfg)
  let inbox = process.new_subject()

  // Takeover + replay happens inside the agent.
  agent.attach_logs(agent_ref, inbox)

  let stream =
    yielder.unfold(from: Nil, with: fn(_) {
      case process.receive(inbox, keep_alive_ms) {
        Ok(event) -> {
          let chunk = bytes_tree.from_string(log_event_sse(event))
          yielder.Next(element: chunk, accumulator: Nil)
        }

        Error(_) -> {
          let chunk = bytes_tree.from_string(": keep-alive\n\n")
          yielder.Next(element: chunk, accumulator: Nil)
        }
      }
    })

  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> response.set_body(mist.Chunked(stream))
}

fn log_event_sse(event: types_log.LogEvent) -> String {
  let types_log.LogEvent(ts_ms: ts_ms, line: line, trace_id: trace_id, ..) =
    event

  let trace_json = case trace_id {
    None -> "null"
    Some(t) -> "\"" <> types_core.trace_id_to_string(t) <> "\""
  }

  let payload =
    "{"
    <> "\"ts_ms\":"
    <> int.to_string(ts_ms)
    <> ","
    <> "\"line\":"
    <> json_string(line)
    <> ","
    <> "\"trace_id\":"
    <> trace_json
    <> "}"

  "data: " <> payload <> "\n\n"
}

fn json_string(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
  |> fn(s) { "\"" <> s <> "\"" }
}

fn handle_reload_profiles(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post -> {
      let Deps(profiles: profiles, ..) = deps

      case
        profiles_sources.reload_profiles(profiles, cfg, call_timeout_ms(cfg))
      {
        Ok(profiles_sources.ReloadSummary(count: count, profile_ids: ids)) ->
          json_response(
            200,
            json.object([
              #("status", json.string("success")),
              #("profiles_loaded", json.int(count)),
              #(
                "profiles",
                json.array(ids, fn(id) {
                  json.string(types_core.profile_id_to_string(id))
                }),
              ),
            ]),
          )

        Error(err) ->
          problem.from_error_kind(
            types_enums.InfraError,
            trace_id,
            req.path,
            string.inspect(err),
          )
      }
    }

    _ -> empty_response(405)
  }
}

fn handle_sys_profiles(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get -> {
      let Deps(profiles: profiles, ..) = deps

      case
        safe_call.call(profiles, registry_timeout_ms(cfg), fn(reply_to) {
          messages.ListProfiles(reply_to)
        })
      {
        Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)

        Ok(ids) -> {
          let timeout_ms = registry_timeout_ms(cfg)

          let metas =
            ids
            |> list.filter_map(fn(id) {
              profile_meta_from_id(profiles, timeout_ms, id)
            })

          json_response(
            200,
            json.object([#("profiles", json.array(metas, fn(x) { x }))]),
          )
        }
      }
    }

    _ -> empty_response(405)
  }
}

fn encode_profile_meta(meta: types_profile.ProfileMeta) -> json.Json {
  json.object([
    #("id", json.string(types_core.profile_id_to_string(meta.id))),
    #("lifecycle", json.string(types_enums.lifecycle_to_string(meta.lifecycle))),
    #("description", json.string(meta.description)),
  ])
}

fn profile_meta_from_id(
  profiles: process.Subject(messages.ProfilesMsg),
  timeout_ms: Int,
  profile_id: types_core.ProfileId,
) -> Result(json.Json, Nil) {
  case lookup.get_profile(profiles, timeout_ms, profile_id) {
    Ok(option.Some(types_profile.Profile(meta: meta, ..))) ->
      Ok(encode_profile_meta(meta))
    _ -> Error(Nil)
  }
}

fn encode_status(status: types_agent.AgentStatusView) -> json.Json {
  json.object([
    #(
      "profile_id",
      json.string(types_core.profile_id_to_string(status.profile_id)),
    ),
    #(
      "instance_id",
      json.string(types_core.instance_id_to_string(status.instance_id)),
    ),
    #(
      "lifecycle",
      json.string(types_enums.lifecycle_to_string(status.lifecycle)),
    ),
    #("phase", json.string(agent_phase_to_string(status.phase))),
    #("mode", json.string(agent_mode_to_string(status.mode))),
    #("assigned_port", case status.assigned_port {
      Some(p) -> json.int(p)
      None -> json.null()
    }),
    #(
      "failure_reason",
      case types_agent.failure_reason_from_phase(status.phase) {
        Some(r) -> json.string(types_agent.failure_reason_to_string(r))
        None -> json.null()
      },
    ),
  ])
}

fn encode_instance_summary(
  req: request.Request(mist.Connection),
  item: types_agent.InstanceSummary,
) -> json.Json {
  let types_agent.InstanceSummary(
    status: status,
    registered_at: registered_at,
    status_updated_at: status_updated_at,
  ) = item

  json.object([
    #(
      "instance_id",
      json.string(types_core.instance_id_to_string(status.instance_id)),
    ),
    #(
      "profile_id",
      json.string(types_core.profile_id_to_string(status.profile_id)),
    ),
    #("a2a_base_url", json.string(a2a_base_url(req, status.instance_id))),
    #(
      "lifecycle",
      json.string(types_enums.lifecycle_to_string(status.lifecycle)),
    ),
    #("phase", json.string(agent_phase_to_string(status.phase))),
    #("mode", json.string(agent_mode_to_string(status.mode))),
    #("assigned_port", case status.assigned_port {
      Some(p) -> json.int(p)
      None -> json.null()
    }),
    #(
      "failure_reason",
      case types_agent.failure_reason_from_phase(status.phase) {
        Some(r) -> json.string(types_agent.failure_reason_to_string(r))
        None -> json.null()
      },
    ),
    #("registered_at", json.int(registered_at)),
    #("status_updated_at", json.int(status_updated_at)),
  ])
}

fn agent_phase_to_string(phase: types_agent.AgentPhase) -> String {
  case phase {
    types_agent.Created -> "created"
    types_agent.Provisioning -> "provisioning"
    types_agent.ReadyTransient -> "ready_transient"
    types_agent.ReadyContinuous -> "ready_continuous"
    types_agent.Stopped -> "stopped"
    types_agent.Failed(_) -> "failed"
  }
}

fn agent_mode_to_string(mode: types_agent.AgentRunMode) -> String {
  case mode {
    types_agent.RunIdle -> "run_idle"
    types_agent.RunBusy -> "run_busy"
  }
}

fn start_error_to_response(
  req: request.Request(mist.Connection),
  trace_id: types_core.TraceId,
  err: messages.StartError,
) -> response.Response(mist.ResponseData) {
  case err {
    messages.ProfileNotFound(profile_id) ->
      problem.not_found(
        trace_id,
        req.path <> ":" <> types_core.profile_id_to_string(profile_id),
      )

    messages.RegistrationFailed(messages.AlreadyExists) ->
      problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        req.path,
        "instance already exists",
      )

    _ ->
      problem.from_error_kind(
        types_enums.InfraError,
        trace_id,
        req.path,
        string.inspect(err),
      )
  }
}

fn parse_instance_id_or_400(
  raw: String,
  trace_id: types_core.TraceId,
  instance: String,
) -> Result(types_core.InstanceId, response.Response(mist.ResponseData)) {
  types_core.instance_id(raw)
  |> result.map_error(fn(_) {
    problem.from_error_kind(
      types_enums.BadRequest,
      trace_id,
      instance,
      "invalid instance_id",
    )
  })
}

fn accepted_json(
  instance_id: types_core.InstanceId,
) -> response.Response(mist.ResponseData) {
  json_response(
    202,
    json.object([
      #("status", json.string("accepted")),
      #(
        "instance_id",
        json.string(types_core.instance_id_to_string(instance_id)),
      ),
    ]),
  )
}

fn initial_status(
  profile_id: String,
  instance_id: types_core.InstanceId,
) -> types_agent.AgentStatusView {
  types_agent.AgentStatusView(
    profile_id: types_core.profile_id(profile_id),
    instance_id: instance_id,
    lifecycle: types_enums.Transient,
    phase: types_agent.Provisioning,
    mode: types_agent.RunIdle,
    assigned_port: None,
  )
}

fn a2a_base_url(
  req: request.Request(mist.Connection),
  instance_id: types_core.InstanceId,
) -> String {
  request_url.a2a_base_url(req, instance_id)
}

fn json_response(
  status: Int,
  payload: json.Json,
) -> response.Response(mist.ResponseData) {
  let body = payload |> json.to_string |> bytes_tree.from_string

  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body))
}

fn empty_response(status: Int) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
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

fn sse_keep_alive_interval_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(stream: stream, ..) = cfg
  let types_config.StreamConfig(sse_keep_alive_interval_ms: ms, ..) = stream
  ms
}

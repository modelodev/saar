//// `/instances/:instance_id/a2a` HTTP API.
////
//// Mission: expose A2A-compatible endpoints per instance.
////
//// Responsibilities:
//// - Implement `GET /instances/:instance_id/.well-known/agent-card.json`.
//// - Implement `POST /instances/:instance_id/a2a/message:send`.
//// - Implement `POST /instances/:instance_id/a2a/message:stream`.
//// - Implement A2A task operations (`GetTask`, `CancelTask`, `SubscribeToTask`).
//// - Enforce request body limits and A2A-compatible RFC7807 responses.
////
//// Non-responsibilities:
//// - Authentication (enforced by `saar/gateway/http_server`).
//// - Agent provisioning and lifecycle management.
////
//// Relationships:
//// - Uses `saar/adapters/a2a` for decoding/encoding.
//// - Resolves `instance_id -> AgentRef` via `saar/gateway/lookup_http`.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/yielder
import mist
import saar/adapters/a2a
import saar/core/agent
import saar/core/messages
import saar/core/task_store
import saar/core/task_store_protocol
import saar/ffi
import saar/gateway/lookup
import saar/gateway/lookup_http
import saar/gateway/problem
import saar/gateway/request_url
import saar/otp/safe_call
import saar/streams/sink
import saar/types/agent as types_agent
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/task as types_task
import youid/uuid

pub type Deps {
  Deps(
    registry: process.Subject(messages.RegistryMsg),
    task_store: process.Subject(task_store_protocol.TaskStoreMsg),
  )
}

type ParsedMessageRequest {
  ParsedMessageRequest(
    trace_id: types_core.TraceId,
    context_id: String,
    message: a2a.A2aMessage,
    extensions: a2a.Extensions,
  )
}

type PreparedInteraction {
  PreparedInteraction(
    trace_id: types_core.TraceId,
    context_id: String,
    extensions: a2a.Extensions,
    response_mode: types_profile.ResponseMode,
    req0: agent.AgentRequest,
    timeout_ms: Int,
  )
}

/// Routes a request under `/instances` for the A2A protocol.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["instances", instance_id, ".well-known", "agent-card.json"] ->
      handle_agent_card(req, cfg, deps, trace_id, instance_id)

    ["instances", instance_id, "a2a", "message:send"] ->
      handle_message_send(req, cfg, deps, trace_id, instance_id)

    ["instances", instance_id, "a2a", "message:stream"] ->
      handle_message_stream(req, cfg, deps, trace_id, instance_id)

    ["instances", instance_id, "a2a", "tasks", task_segment] ->
      handle_task_request(req, cfg, deps, trace_id, instance_id, task_segment)

    _ -> problem.not_found_a2a(trace_id)
  }
}

fn handle_agent_card(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get ->
      case parse_instance_id_or_400(instance_raw, trace_id) {
        Error(resp) -> resp
        Ok(instance_id) -> {
          let Deps(registry: registry, ..) = deps

          lookup_http.with_agent_ref(
            registry,
            registry_timeout_ms(cfg),
            trace_id,
            req.path,
            instance_id,
            fn(agent_ref) {
              case agent.info(agent_ref, status_timeout_ms(cfg)) {
                Error(call_err) ->
                  problem.from_call_error_a2a(call_err, trace_id)
                Ok(info) -> {
                  let base_url = case request_url.base_url(req) {
                    Some(base) -> base
                    None -> ""
                  }

                  let card = a2a.agent_card_from_instance(info, base_url)

                  json_response(200, card)
                }
              }
            },
          )
        }
      }

    _ -> empty_response(405)
  }
}

fn handle_message_send(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_instance_id_or_400(instance_raw, trace_id) {
        Error(resp) -> resp
        Ok(instance_id) -> {
          let Deps(registry: registry, ..) = deps

          lookup_http.with_agent_ref(
            registry,
            registry_timeout_ms(cfg),
            trace_id,
            req.path,
            instance_id,
            fn(agent_ref) {
              message_send_with_agent(req, cfg, deps, trace_id, agent_ref)
            },
          )
        }
      }

    _ -> empty_response(405)
  }
}

fn message_send_with_agent(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  server_trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
) -> response.Response(mist.ResponseData) {
  case parse_message_request(req, cfg, server_trace_id) {
    Error(resp) -> resp
    Ok(parsed) ->
      case prepare_interaction(cfg, server_trace_id, agent_ref, parsed) {
        Error(resp) -> resp
        Ok(prepared) -> {
          let PreparedInteraction(
            trace_id: trace_id,
            context_id: context_id,
            response_mode: response_mode,
            req0: req0,
            timeout_ms: timeout_ms,
            ..,
          ) = prepared

          case response_mode {
            types_profile.ResponseModeDeferred ->
              interact_deferred_a2a(cfg, deps, agent_ref, prepared)

            _ ->
              case
                agent.interact(agent_ref, req0, sink.NonStreaming, timeout_ms)
              {
                Ok(result) ->
                  json_response(
                    200,
                    a2a.message_send_response(result, context_id),
                  )

                Error(err) ->
                  problem.from_error_kind_a2a(err.kind, trace_id, err.message)
              }
          }
        }
      }
  }
}

fn handle_message_stream(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_instance_id_or_400(instance_raw, trace_id) {
        Error(resp) -> resp
        Ok(instance_id) -> {
          let Deps(registry: registry, ..) = deps

          lookup_http.with_agent_ref(
            registry,
            registry_timeout_ms(cfg),
            trace_id,
            req.path,
            instance_id,
            fn(agent_ref) {
              message_stream_with_agent(req, cfg, trace_id, agent_ref)
            },
          )
        }
      }

    _ -> empty_response(405)
  }
}

fn message_stream_with_agent(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  server_trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
) -> response.Response(mist.ResponseData) {
  case parse_message_request(req, cfg, server_trace_id) {
    Error(resp) -> resp
    Ok(parsed) ->
      case prepare_interaction(cfg, server_trace_id, agent_ref, parsed) {
        Error(resp) -> resp
        Ok(prepared) -> {
          let keep_alive_ms = sse_keep_alive_interval_ms(cfg)

          let PreparedInteraction(
            trace_id: trace_id,
            context_id: context_id,
            extensions: extensions,
            req0: req0,
            timeout_ms: timeout_ms,
            ..,
          ) = prepared

          let protocol = select_wire_protocol(extensions)

          interact_streaming_a2a(
            trace_id,
            context_id,
            protocol,
            extensions,
            keep_alive_ms,
            agent_ref,
            req0,
            timeout_ms,
          )
        }
      }
  }
}

fn handle_task_request(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
  task_segment: String,
) -> response.Response(mist.ResponseData) {
  case parse_instance_id_or_400(instance_raw, trace_id) {
    Error(resp) -> resp
    Ok(instance_id) ->
      case string.split_once(task_segment, on: ":") {
        Error(_) ->
          handle_task_get(req, cfg, deps, trace_id, instance_id, task_segment)

        Ok(#(task_id_raw, "cancel")) ->
          handle_task_cancel(req, cfg, deps, trace_id, instance_id, task_id_raw)

        Ok(#(task_id_raw, "subscribe")) ->
          handle_task_subscribe(
            req,
            cfg,
            deps,
            trace_id,
            instance_id,
            task_id_raw,
          )

        Ok(_) -> problem.not_found_a2a(trace_id)
      }
  }
}

fn handle_task_get(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_id: types_core.InstanceId,
  task_id_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get ->
      case parse_task_id_or_400(task_id_raw, trace_id) {
        Error(resp) -> resp
        Ok(task_id) ->
          case
            find_task_for_instance(cfg, deps, trace_id, task_id, instance_id)
          {
            Error(resp) -> resp
            Ok(record) -> json_response(200, a2a.task_record_to_task(record))
          }
      }

    _ -> empty_response(405)
  }
}

fn handle_task_cancel(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_id: types_core.InstanceId,
  task_id_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_task_id_or_400(task_id_raw, trace_id) {
        Error(resp) -> resp
        Ok(task_id) ->
          case
            find_task_for_instance(cfg, deps, trace_id, task_id, instance_id)
          {
            Error(resp) -> resp
            Ok(record) -> cancel_task_record(cfg, deps, trace_id, record)
          }
      }

    _ -> empty_response(405)
  }
}

fn handle_task_subscribe(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_id: types_core.InstanceId,
  task_id_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case parse_task_id_or_400(task_id_raw, trace_id) {
        Error(resp) -> resp
        Ok(task_id) ->
          case
            find_task_for_instance(cfg, deps, trace_id, task_id, instance_id)
          {
            Error(resp) -> resp
            Ok(record) ->
              subscribe_task_response(cfg, deps, instance_id, record)
          }
      }

    _ -> empty_response(405)
  }
}

fn cancel_task_record(
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let types_task.TaskRecord(status: status, ..) = record

  case status {
    types_task.TaskRunning -> cancel_running_task(cfg, deps, trace_id, record)
    _ -> json_response(200, a2a.task_record_to_task(record))
  }
}

fn cancel_running_task(
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  cancel_agent_task(cfg, deps, record)

  case
    task_store.cancel_task(
      store,
      task_timeout_ms(cfg),
      record.id,
      cancel_error(record.id),
      ffi.now_ms(),
    )
  {
    Ok(updated) -> json_response(200, a2a.task_record_to_task(updated))
    Error(safe_call.CallFailed(call_err)) ->
      problem.from_call_error_a2a(call_err, trace_id)
    Error(safe_call.ActorError(err)) ->
      task_store_error_to_response(trace_id, err)
  }
}

fn subscribe_task_response(
  cfg: types_config.SaarConfig,
  deps: Deps,
  instance_id: types_core.InstanceId,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let keep_alive_ms = sse_keep_alive_interval_ms(cfg)
  let types_task.TaskRecord(id: task_id, status: status, ..) = record

  let stream =
    yielder.unfold(
      from: SubscribeState(
        sent_initial: False,
        last_status: status,
        closed: types_task.task_status_is_terminal(status),
      ),
      with: fn(state) {
        next_subscription_step(
          cfg,
          deps,
          instance_id,
          record,
          task_id,
          state,
          keep_alive_ms,
        )
      },
    )

  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> response.set_body(mist.Chunked(stream))
}

type SubscribeState {
  SubscribeState(
    sent_initial: Bool,
    last_status: types_task.TaskStatus,
    closed: Bool,
  )
}

fn next_subscription_step(
  cfg: types_config.SaarConfig,
  deps: Deps,
  instance_id: types_core.InstanceId,
  initial_record: types_task.TaskRecord,
  task_id: types_core.TraceId,
  state: SubscribeState,
  keep_alive_ms: Int,
) -> yielder.Step(bytes_tree.BytesTree, SubscribeState) {
  case state.sent_initial {
    False ->
      yielder.Next(
        element: task_event_chunk_for(initial_record),
        accumulator: SubscribeState(
          sent_initial: True,
          last_status: state.last_status,
          closed: state.closed,
        ),
      )

    True ->
      case state.closed {
        True -> yielder.Done
        False ->
          poll_task_for_updates(
            cfg,
            deps,
            instance_id,
            task_id,
            state,
            keep_alive_ms,
          )
      }
  }
}

fn poll_task_for_updates(
  cfg: types_config.SaarConfig,
  deps: Deps,
  instance_id: types_core.InstanceId,
  task_id: types_core.TraceId,
  state: SubscribeState,
  keep_alive_ms: Int,
) -> yielder.Step(bytes_tree.BytesTree, SubscribeState) {
  process.sleep(keep_alive_ms)

  case fetch_task_record(cfg, deps, task_id, instance_id) {
    option.None -> yielder.Done
    option.Some(record) ->
      case record.status == state.last_status {
        True ->
          yielder.Next(
            element: bytes_tree.from_string(": keep-alive\n\n"),
            accumulator: state,
          )

        False -> {
          let next_state =
            SubscribeState(
              sent_initial: True,
              last_status: record.status,
              closed: types_task.task_status_is_terminal(record.status),
            )
          let chunk = task_event_chunk_for(record)
          yielder.Next(element: chunk, accumulator: next_state)
        }
      }
  }
}

fn task_event_chunk_for(record: types_task.TaskRecord) -> bytes_tree.BytesTree {
  let payload = a2a.task_record_to_task(record) |> json.to_string
  bytes_tree.from_string("data: " <> payload <> "\n\n")
}

fn fetch_task_record(
  cfg: types_config.SaarConfig,
  deps: Deps,
  task_id: types_core.TraceId,
  instance_id: types_core.InstanceId,
) -> option.Option(types_task.TaskRecord) {
  let Deps(task_store: store, ..) = deps
  let timeout_ms = task_timeout_ms(cfg)

  case task_store.get_task(store, timeout_ms, task_id) {
    Ok(option.Some(record)) ->
      case record.instance_id == instance_id {
        True -> option.Some(record)
        False -> option.None
      }
    _ -> option.None
  }
}

fn find_task_for_instance(
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
  instance_id: types_core.InstanceId,
) -> Result(types_task.TaskRecord, response.Response(mist.ResponseData)) {
  let Deps(task_store: store, ..) = deps

  case task_store.get_task(store, task_timeout_ms(cfg), task_id) {
    Error(call_err) -> Error(problem.from_call_error_a2a(call_err, trace_id))
    Ok(option.None) -> Error(problem.not_found_a2a(trace_id))
    Ok(option.Some(record)) ->
      case record.instance_id == instance_id {
        True -> Ok(record)
        False -> Error(problem.not_found_a2a(trace_id))
      }
  }
}

fn parse_task_id_or_400(
  raw: String,
  trace_id: types_core.TraceId,
) -> Result(types_core.TraceId, response.Response(mist.ResponseData)) {
  case a2a.validate_task_id(raw) {
    Ok(_) -> Ok(types_core.trace_id(raw))
    Error(_) ->
      Error(problem.from_error_kind_a2a(
        types_enums.BadRequest,
        trace_id,
        "invalid task id",
      ))
  }
}

fn cancel_agent_task(
  cfg: types_config.SaarConfig,
  deps: Deps,
  record: types_task.TaskRecord,
) -> Nil {
  let Deps(registry: registry, ..) = deps

  case
    lookup.lookup_agent_ref(
      registry,
      registry_timeout_ms(cfg),
      record.instance_id,
    )
  {
    Ok(option.Some(agent_ref)) -> {
      let _ = agent.cancel_interaction(agent_ref, record.id, 1000)
      Nil
    }
    _ -> Nil
  }
}

fn cancel_error(trace_id: types_core.TraceId) -> types_output.InteractionError {
  types_output.saar_error(trace_id, types_enums.AgentError, "cancelled")
}

fn interact_deferred_a2a(
  cfg: types_config.SaarConfig,
  deps: Deps,
  agent_ref: agent.AgentRef,
  prepared: PreparedInteraction,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let PreparedInteraction(
    trace_id: trace_id,
    context_id: context_id,
    req0: req0,
    timeout_ms: _timeout_ms,
    ..,
  ) = prepared
  let agent.AgentRequest(instance_id: instance_id, capability: capability, ..) =
    req0

  case
    task_store.create_task(
      store,
      task_timeout_ms(cfg),
      trace_id,
      instance_id,
      capability,
      option.Some(context_id),
      ffi.now_ms(),
    )
  {
    Ok(result) -> handle_created_task(cfg, deps, agent_ref, prepared, result)
    Error(safe_call.CallFailed(call_err)) ->
      problem.from_call_error_a2a(call_err, trace_id)
    Error(safe_call.ActorError(err)) ->
      task_store_error_to_response(trace_id, err)
  }
}

fn handle_created_task(
  cfg: types_config.SaarConfig,
  deps: Deps,
  agent_ref: agent.AgentRef,
  prepared: PreparedInteraction,
  result: types_task.TaskCreateResult,
) -> response.Response(mist.ResponseData) {
  let record = types_task.task_create_record(result)

  case result {
    types_task.TaskExisting(_) -> json_response(200, a2a_task_response(record))

    types_task.TaskCreated(_) ->
      case agent.status(agent_ref, status_timeout_ms(cfg)) {
        Error(call_err) -> task_create_call_failed(cfg, deps, record, call_err)

        Ok(status) ->
          case status.mode {
            types_agent.RunBusy -> task_create_busy(cfg, deps, record)
            types_agent.RunIdle -> {
              start_deferred_interaction(cfg, deps, agent_ref, prepared)
              json_response(200, a2a_task_response(record))
            }
          }
      }
  }
}

fn a2a_task_response(record: types_task.TaskRecord) -> json.Json {
  json.object([
    #("result", a2a.task_record_to_task(record)),
  ])
}

fn task_create_call_failed(
  cfg: types_config.SaarConfig,
  deps: Deps,
  record: types_task.TaskRecord,
  call_err: safe_call.CallError,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let _ = task_store.delete_task(store, task_timeout_ms(cfg), record.id)
  problem.from_call_error_a2a(call_err, record.id)
}

fn task_create_busy(
  cfg: types_config.SaarConfig,
  deps: Deps,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let _ = task_store.delete_task(store, task_timeout_ms(cfg), record.id)

  problem.from_error_kind_a2a(
    types_enums.AgentError,
    record.id,
    "Agent is busy",
  )
}

fn start_deferred_interaction(
  cfg: types_config.SaarConfig,
  deps: Deps,
  agent_ref: agent.AgentRef,
  prepared: PreparedInteraction,
) -> Nil {
  let Deps(task_store: store, ..) = deps
  let PreparedInteraction(
    trace_id: trace_id,
    req0: req0,
    timeout_ms: timeout_ms,
    ..,
  ) = prepared

  let _ =
    process.spawn(fn() {
      let result =
        agent.interact(agent_ref, req0, sink.NonStreaming, timeout_ms)
      let now_ms = ffi.now_ms()

      case result {
        Ok(output) -> {
          let _ =
            task_store.complete_task(
              store,
              task_timeout_ms(cfg),
              trace_id,
              output,
              now_ms,
            )
          Nil
        }

        Error(err) -> handle_deferred_error(cfg, deps, err, now_ms)
      }
    })

  Nil
}

fn handle_deferred_error(
  cfg: types_config.SaarConfig,
  deps: Deps,
  err: types_output.InteractionError,
  now_ms: Int,
) -> Nil {
  let Deps(task_store: store, ..) = deps

  case err.kind, err.message {
    types_enums.AgentError, "cancelled" -> {
      let _ =
        task_store.cancel_task(
          store,
          task_timeout_ms(cfg),
          err.trace_id,
          err,
          now_ms,
        )
      Nil
    }

    _, _ -> {
      let _ =
        task_store.fail_task(
          store,
          task_timeout_ms(cfg),
          err.trace_id,
          err,
          now_ms,
        )
      Nil
    }
  }
}

fn parse_message_request(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  server_trace_id: types_core.TraceId,
) -> Result(ParsedMessageRequest, response.Response(mist.ResponseData)) {
  let max_body = max_request_body_bytes(cfg)
  let extensions = parse_extensions(req)

  let read = case mist.read_body(req, max_body) {
    Ok(req_with_body) -> Ok(req_with_body)
    Error(mist.ExcessBody) ->
      Error(problem.request_body_too_large_a2a(server_trace_id))
    Error(_) ->
      Error(problem.from_error_kind_a2a(
        types_enums.BadRequest,
        server_trace_id,
        "malformed body",
      ))
  }

  use req_with_body <- result.try(read)

  let body = bit_array.to_string(req_with_body.body) |> result.unwrap("")

  use decoded <- result.try(
    a2a.decode_message_send_request(body, extensions)
    |> result.map_error(fn(err) {
      problem.from_error_kind_a2a(
        types_enums.BadRequest,
        server_trace_id,
        "invalid request: " <> decode_error_to_string(err),
      )
    }),
  )

  let a2a.MessageSendRequest(message: message, context_id: maybe_context) =
    decoded

  let trace_id = types_core.trace_id(uuid.v7_string())
  let context_id = case maybe_context {
    Some(id) -> id
    None -> uuid.v7_string()
  }

  Ok(ParsedMessageRequest(
    trace_id: trace_id,
    context_id: context_id,
    message: message,
    extensions: extensions,
  ))
}

fn prepare_interaction(
  cfg: types_config.SaarConfig,
  server_trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
  parsed: ParsedMessageRequest,
) -> Result(PreparedInteraction, response.Response(mist.ResponseData)) {
  let ParsedMessageRequest(
    trace_id: trace_id,
    context_id: context_id,
    message: message,
    extensions: extensions,
  ) = parsed

  use info <- result.try(
    agent.info(agent_ref, status_timeout_ms(cfg))
    |> result.map_error(fn(call_err) {
      problem.from_call_error_a2a(call_err, server_trace_id)
    }),
  )

  use capability <- result.try(
    pick_capability(info.interface)
    |> result.map_error(fn(_) {
      problem.from_error_kind_a2a(
        types_enums.BadRequest,
        server_trace_id,
        "agent has no capabilities",
      )
    }),
  )

  let response_mode = capability_response_mode(info.interface, capability)

  let payload = a2a.message_to_payload(message)

  let ctx =
    types_input.RequestContext(
      trace_id: trace_id,
      extra: dict.from_list([#("context_id", context_id)]),
    )

  let req0 =
    agent.AgentRequest(
      profile_id: info.meta.id,
      instance_id: info.status.instance_id,
      capability: capability,
      inputs: payload,
      context: ctx,
    )

  let timeout_ms =
    agent.resolve_call_timeout_for(cfg, info.interface, capability)

  Ok(PreparedInteraction(
    trace_id: trace_id,
    context_id: context_id,
    extensions: extensions,
    response_mode: response_mode,
    req0: req0,
    timeout_ms: timeout_ms,
  ))
}

fn interact_streaming_a2a(
  trace_id: types_core.TraceId,
  context_id: String,
  protocol: sink.WireProtocol,
  extensions: a2a.Extensions,
  keep_alive_ms: Int,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
) -> response.Response(mist.ResponseData) {
  let inbox: process.Subject(WriterMsg) = process.new_subject()

  let writer =
    sink.SseWriter(
      write: fn(data) {
        let reply_to = process.new_subject()
        process.send(inbox, Write(data, reply_to))
        case process.receive(reply_to, 10_000) {
          Ok(out) -> out
          Error(_) -> Error(safe_call.TimedOut)
        }
      },
      close: fn() { process.send(inbox, Close) },
    )

  let stream_sink = sink.start_sse_sink(writer, protocol, keep_alive_ms)

  let _pid =
    process.spawn(fn() {
      let out =
        agent.interact(agent_ref, req0, sink.Streaming(stream_sink), timeout_ms)

      case out {
        Ok(_) -> Nil
        Error(err) -> {
          let state0 = a2a.new_stream(trace_id, context_id, extensions)

          let #(state1, started) =
            a2a.convert_stream(
              state0,
              a2a.StreamStarted(task_id: trace_id, context_id: context_id),
            )

          let #(_state2, terminal) =
            a2a.convert_stream(state1, a2a.StreamError(err))

          let events = list.append(started, terminal)

          let _ = sink.push_batch(stream_sink, events, 250)
          let _ = sink.finish(stream_sink, 250)
          Nil
        }
      }
    })

  let body_stream =
    yielder.unfold(from: False, with: fn(closed) {
      case closed {
        True -> yielder.Done
        False ->
          case process.receive(inbox, 60_000) {
            Ok(Write(data, reply_to)) -> {
              process.send(reply_to, Ok(Nil))
              yielder.Next(
                element: bytes_tree.from_string(data),
                accumulator: False,
              )
            }
            Ok(Close) -> yielder.Done
            Error(_) ->
              yielder.Next(
                element: bytes_tree.from_string(": keep-alive\n\n"),
                accumulator: False,
              )
          }
      }
    })

  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> response.set_body(mist.Chunked(body_stream))
}

type WriterMsg {
  Write(String, process.Subject(Result(Nil, safe_call.CallError)))
  Close
}

fn parse_extensions(req: request.Request(mist.Connection)) -> a2a.Extensions {
  case request.get_header(req, "x-a2a-extensions") {
    Ok(value) ->
      case string.contains(value, "https://a2ui.org/a2a-extension/a2ui/v0.8") {
        True -> a2a.A2uiV08
        False -> a2a.NoExtensions
      }

    Error(_) -> a2a.NoExtensions
  }
}

fn select_wire_protocol(extensions: a2a.Extensions) -> sink.WireProtocol {
  case extensions {
    a2a.A2uiV08 -> sink.A2aA2uiV08
    a2a.NoExtensions -> sink.A2a
  }
}

fn decode_error_to_string(err: a2a.DecodeError) -> String {
  case err {
    a2a.MissingMessage -> "missing message"
    a2a.MissingParts -> "missing parts"
    a2a.MissingAgentCardName -> "missing agent card name"
    a2a.MissingAgentCardUrl -> "missing agent card url"
    a2a.InvalidRole(_) -> "invalid role"
    a2a.InvalidTaskId(_) -> "invalid task id"
    a2a.FileBytesRejected -> "file.bytes is not supported"
    a2a.A2uiExtensionRequired -> "A2UI extension required"
    a2a.InvalidA2uiMimeType(_) -> "invalid A2UI mimeType"
    a2a.InvalidA2uiShape -> "invalid A2UI shape"
  }
}

fn parse_instance_id_or_400(
  raw: String,
  trace_id: types_core.TraceId,
) -> Result(types_core.InstanceId, response.Response(mist.ResponseData)) {
  case types_core.instance_id(raw) {
    Ok(id) -> Ok(id)
    Error(_) ->
      Error(problem.from_error_kind_a2a(
        types_enums.BadRequest,
        trace_id,
        "invalid instance_id",
      ))
  }
}

fn pick_capability(interface: types_profile.Interface) -> Result(String, Nil) {
  case interface {
    types_profile.RunnerInterface(caps) -> pick_capability_from_dict(caps)
    types_profile.HttpInterface(_, _, _, caps) ->
      pick_capability_from_dict(caps)
  }
}

fn pick_capability_from_dict(
  caps: dict.Dict(String, cap),
) -> Result(String, Nil) {
  case dict.has_key(caps, "chat") {
    True -> Ok("chat")
    False ->
      case dict.to_list(caps) {
        [] -> Error(Nil)
        [#(id, _), ..] -> Ok(id)
      }
  }
}

// Local copy to avoid exporting gateway internals from agents_api.
fn capability_response_mode(
  interface: types_profile.Interface,
  capability: String,
) -> types_profile.ResponseMode {
  case interface {
    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.response_mode
        Error(_) -> types_profile.ResponseModeSync
      }

    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.response_mode
        Error(_) -> types_profile.ResponseModeSync
      }
  }
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

fn registry_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(registry_timeout_ms: ms, ..) = timeouts
  ms
}

fn status_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(status_timeout_ms: ms, ..) = timeouts
  ms
}

fn max_request_body_bytes(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(limits: limits, ..) = cfg
  let types_config.SaarLimits(max_request_body_bytes: bytes, ..) = limits
  bytes
}

fn task_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(call_timeout_ms: call_timeout_ms, ..) = timeouts
  call_timeout_ms
}

fn task_store_error_to_response(
  trace_id: types_core.TraceId,
  err: types_task.TaskStoreError,
) -> response.Response(mist.ResponseData) {
  case err {
    types_task.TaskNotFound -> problem.not_found_a2a(trace_id)
    types_task.TaskLimitReached(_) ->
      problem.from_error_kind_a2a(
        types_enums.InfraError,
        trace_id,
        "max tasks reached",
      )
    types_task.TaskResultTooLarge(_, _) ->
      problem.from_error_kind_a2a(
        types_enums.InfraError,
        trace_id,
        "task result too large",
      )
  }
}

fn sse_keep_alive_interval_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(stream: stream, ..) = cfg
  let types_config.StreamConfig(sse_keep_alive_interval_ms: ms, ..) = stream
  ms
}

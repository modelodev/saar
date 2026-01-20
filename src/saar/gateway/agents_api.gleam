//// `/agents` HTTP API.
////
//// Mission: expose native per-instance information and interaction endpoints.
////
//// Responsibilities:
//// - Implement `GET /agents/:instance_id` (safe info + capabilities).
//// - Implement `POST /agents/:instance_id/interact` (sync JSON or SSE).
//// - Enforce request body limits and stable error semantics via `problem.gleam`.
////
//// Non-responsibilities:
//// - Managing instance lifecycle (`/sys/agents` does that).
//// - Implementing runner/HTTP bridge logic (handled by core/bridge modules).
////
//// Relationships:
//// - Routed by `saar/gateway/http_server` after auth.
//// - Resolves `instance_id -> AgentRef` via the Registry actor.
//// - Invokes `saar/core/agent` for info and interactions.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/yielder
import mist
import saar/adapters/agui
import saar/core/agent
import saar/core/messages
import saar/core/task_store
import saar/core/task_store_protocol
import saar/decoders
import saar/gateway/lookup_http
import saar/gateway/problem
import saar/gateway/request_url
import saar/gateway/tasks_api
import saar/ingest_metadata
import saar/otp/safe_call
import saar/streams/sink

import saar/ffi
import saar/types/agent as types_agent
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/stream
import saar/types/task as types_task
import youid/uuid

pub type Deps {
  Deps(
    registry: process.Subject(messages.RegistryMsg),
    task_store: process.Subject(task_store_protocol.TaskStoreMsg),
  )
}

/// Routes a request under `/agents`.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let segments = request.path_segments(req)

  case segments {
    ["agents", instance_id] ->
      handle_agent_info(req, cfg, deps, trace_id, instance_id)
    ["agents", instance_id, "interact"] ->
      handle_agent_interact(req, cfg, deps, trace_id, instance_id)
    _ -> problem.not_found(trace_id, req.path)
  }
}

fn handle_agent_info(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
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
            fn(agent_ref) {
              case agent.info(agent_ref, status_timeout_ms(cfg)) {
                Error(call_err) ->
                  problem.from_call_error(call_err, trace_id, req.path)
                Ok(info) -> json_response(200, encode_agent_info(req, info))
              }
            },
          )
        }
      }

    _ -> empty_response(405)
  }
}

fn handle_agent_interact(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  instance_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Post ->
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
            fn(agent_ref) {
              interact_with_agent(req, cfg, deps, trace_id, agent_ref)
            },
          )
        }
      }

    _ -> empty_response(405)
  }
}

type InteractParsed {
  InteractParsed(
    capability: String,
    inputs: Dynamic,
    trace_id: Option(types_core.TraceId),
  )
}

fn interact_with_agent(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  server_trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
) -> response.Response(mist.ResponseData) {
  let max_body = max_request_body_bytes(cfg)

  case mist.read_body(req, max_body) {
    Error(mist.ExcessBody) ->
      problem.request_body_too_large(server_trace_id, req.path)

    Error(_) ->
      problem.from_error_kind(
        types_enums.BadRequest,
        server_trace_id,
        req.path,
        "malformed body",
      )

    Ok(req_with_body) -> {
      let body =
        bit_array.to_string(req_with_body.body)
        |> result.unwrap("")

      case decode_interact_body(body) {
        Error(message) ->
          problem.from_error_kind(
            types_enums.BadRequest,
            server_trace_id,
            req.path,
            message,
          )

        Ok(InteractParsed(
          capability: capability,
          inputs: inputs,
          trace_id: maybe_trace,
        )) -> {
          let trace_id = case maybe_trace {
            Some(t) -> t
            None -> types_core.trace_id(uuid.v7_string())
          }

          // Load profile snapshot to validate schema and to decide sync vs SSE.
          case agent.info(agent_ref, status_timeout_ms(cfg)) {
            Error(call_err) ->
              problem.from_call_error(call_err, server_trace_id, req.path)

            Ok(info) -> {
              let schema = capability_input_schema(info.interface, capability)

              case decode_inputs(schema, inputs) {
                Error(err) ->
                  problem.from_error_kind(
                    types_enums.BadRequest,
                    trace_id,
                    req.path,
                    err,
                  )

                Ok(payload) -> {
                  let files_semantics =
                    capability_files_semantics(info.interface, capability)

                  case validate_files_cardinality(files_semantics, payload) {
                    Error(#(max_files, received_files)) ->
                      problem.bad_request_with_code(
                        trace_id,
                        req.path,
                        files_cardinality_detail(
                          capability,
                          max_files,
                          received_files,
                        ),
                        "invalid_input",
                      )

                    Ok(_) -> {
                      let ctx =
                        types_input.RequestContext(
                          trace_id: trace_id,
                          extra: dict.new(),
                        )
                      let req0 =
                        agent.AgentRequest(
                          profile_id: info.meta.id,
                          instance_id: info.status.instance_id,
                          capability: capability,
                          inputs: payload,
                          context: ctx,
                        )
                      let response_mode =
                        capability_response_mode(info.interface, capability)
                      let timeout_ms =
                        agent.resolve_call_timeout_for(
                          cfg,
                          info.interface,
                          capability,
                        )

                      case response_mode {
                        types_profile.ResponseModeSync ->
                          interact_sync(
                            req,
                            trace_id,
                            agent_ref,
                            req0,
                            timeout_ms,
                            files_semantics,
                          )

                        types_profile.ResponseModeStream ->
                          interact_streaming(
                            req,
                            cfg,
                            trace_id,
                            agent_ref,
                            req0,
                            timeout_ms,
                          )

                        types_profile.ResponseModeDeferred ->
                          interact_deferred(
                            req,
                            cfg,
                            deps,
                            trace_id,
                            agent_ref,
                            req0,
                            timeout_ms,
                          )
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn interact_sync(
  req: request.Request(mist.Connection),
  trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
  files_semantics: Option(types_profile.FilesSemantics),
) -> response.Response(mist.ResponseData) {
  let out = agent.interact(agent_ref, req0, sink.NonStreaming, timeout_ms)

  case out {
    Ok(result) -> {
      let result =
        ingest_metadata.attach_ingest_metadata(files_semantics, result)
      json_response(200, encode_interaction_result(result))
    }

    Error(err) -> interaction_error_to_response(req, trace_id, err)
  }
}

fn interact_streaming(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
) -> response.Response(mist.ResponseData) {
  let protocol = select_wire_protocol(req)
  let keep_alive_ms = sse_keep_alive_interval_ms(cfg)

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

  // Trigger the interaction asynchronously so we can return the SSE response.
  let _pid =
    process.spawn(fn() {
      let out =
        agent.interact(agent_ref, req0, sink.Streaming(stream_sink), timeout_ms)

      // If the interaction errors before any streaming can happen (e.g. Busy),
      // emit a terminal payload best-effort for AG-UI.
      case out {
        Ok(_) -> Nil
        Error(err) ->
          case protocol {
            sink.AgUi -> {
              let payload = agui_run_error(trace_id, err)
              let _ = sink.push_batch(stream_sink, [payload], 250)
              let _ = sink.finish(stream_sink, 250)
              Nil
            }
            _ -> {
              let _ = sink.finish(stream_sink, 250)
              Nil
            }
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

fn interact_deferred(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let agent.AgentRequest(instance_id: instance_id, capability: capability, ..) =
    req0

  case
    task_store.create_task(
      store,
      task_timeout_ms(cfg),
      trace_id,
      instance_id,
      capability,
      None,
      ffi.now_ms(),
    )
  {
    Ok(result) ->
      handle_created_task(req, cfg, deps, agent_ref, req0, timeout_ms, result)
    Error(safe_call.CallFailed(call_err)) ->
      problem.from_call_error(call_err, trace_id, req.path)
    Error(safe_call.ActorError(err)) ->
      task_store_error_to_response(trace_id, req.path, err)
  }
}

fn handle_created_task(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
  result: types_task.TaskCreateResult,
) -> response.Response(mist.ResponseData) {
  let record = types_task.task_create_record(result)

  case result {
    types_task.TaskExisting(_) ->
      json_response(202, tasks_api.encode_task_record(record))

    types_task.TaskCreated(_) ->
      case agent.status(agent_ref, status_timeout_ms(cfg)) {
        Error(call_err) ->
          task_create_call_failed(req, cfg, deps, record, call_err)
        Ok(status) ->
          case status.mode {
            types_agent.RunBusy -> task_create_busy(req, cfg, deps, record)
            types_agent.RunIdle -> {
              start_deferred_interaction(cfg, deps, agent_ref, req0, timeout_ms)
              json_response(202, tasks_api.encode_task_record(record))
            }
          }
      }
  }
}

fn task_create_call_failed(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  record: types_task.TaskRecord,
  call_err: safe_call.CallError,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let _ = task_store.delete_task(store, task_timeout_ms(cfg), record.id)
  problem.from_call_error(call_err, record.id, req.path)
}

fn task_create_busy(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps
  let _ = task_store.delete_task(store, task_timeout_ms(cfg), record.id)

  problem.from_error_kind(
    types_enums.AgentError,
    record.id,
    req.path,
    "Agent is busy",
  )
}

fn start_deferred_interaction(
  cfg: types_config.SaarConfig,
  deps: Deps,
  agent_ref: agent.AgentRef,
  req0: agent.AgentRequest,
  timeout_ms: Int,
) -> Nil {
  let Deps(task_store: store, ..) = deps

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
              output.trace_id,
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

type WriterMsg {
  Write(String, process.Subject(Result(Nil, safe_call.CallError)))
  Close
}

fn select_wire_protocol(
  req: request.Request(mist.Connection),
) -> sink.WireProtocol {
  case request.get_header(req, "x-saar-ui-protocol") {
    Ok("a2ui/v0.8") -> sink.A2uiV08
    _ -> sink.AgUi
  }
}

fn agui_run_error(
  trace_id: types_core.TraceId,
  err: types_output.InteractionError,
) -> stream.StreamEvent {
  agui.run_error(trace_id, err)
}

fn decode_interact_body(body: String) -> Result(InteractParsed, String) {
  use value <- result.try(
    json.parse(body, decode.dynamic)
    |> result.map_error(fn(_) { "invalid json" }),
  )

  let decoder = {
    use capability <- decode.field("capability", decode.string)
    use inputs <- decode.field("inputs", decode.dynamic)
    use ctx <- decode.optional_field(
      "context",
      dict.new(),
      decode.dict(decode.string, decode.dynamic),
    )

    decode.success(#(capability, inputs, ctx))
  }

  use decoded <- result.try(
    decode.run(value, decoder)
    |> result.map_error(fn(_) { "invalid request" }),
  )

  let #(capability, inputs, ctx) = decoded

  let trace_id = case dict.get(ctx, "trace_id") {
    Ok(dyn) ->
      case decode.run(dyn, decode.string) {
        Ok(s) -> Some(types_core.trace_id(s))
        Error(_) -> None
      }
    Error(_) -> None
  }

  Ok(InteractParsed(capability: capability, inputs: inputs, trace_id: trace_id))
}

fn decode_inputs(
  schema: Option(types_profile.InputSchema),
  inputs: Dynamic,
) -> Result(types_input.InputPayload, String) {
  case schema {
    None ->
      // Default to std:chat for v0 convenience.
      decoders.decode_payload_std_chat(inputs, dict.new())
      |> result.map_error(fn(errs) { string.inspect(errs) })

    Some(types_profile.SchemaChat) ->
      decoders.decode_payload_std_chat(inputs, dict.new())
      |> result.map_error(fn(errs) { string.inspect(errs) })

    Some(types_profile.SchemaFiles) ->
      decoders.decode_payload_std_files(inputs)
      |> result.map_error(fn(errs) { string.inspect(errs) })

    Some(types_profile.SchemaChatExtended(extra_fields)) ->
      decoders.decode_payload_std_chat(inputs, extra_fields)
      |> result.map_error(fn(errs) { string.inspect(errs) })
  }
}

fn capability_input_schema(
  interface: types_profile.Interface,
  capability: String,
) -> Option(types_profile.InputSchema) {
  case interface {
    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.input_schema
        Error(_) -> None
      }

    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.input_schema
        Error(_) -> None
      }
  }
}

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

fn capability_files_semantics(
  interface: types_profile.Interface,
  capability: String,
) -> Option(types_profile.FilesSemantics) {
  case interface {
    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.files
        Error(_) -> None
      }

    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> cap.files
        Error(_) -> None
      }
  }
}

fn validate_files_cardinality(
  files_semantics: Option(types_profile.FilesSemantics),
  payload: types_input.InputPayload,
) -> Result(Nil, #(Int, Int)) {
  case files_semantics {
    None -> Ok(Nil)
    Some(types_profile.FilesSemantics(max_files: max_files, ..)) -> {
      let received_files = types_input.payload_file_count(payload)

      case received_files > max_files {
        True -> Error(#(max_files, received_files))
        False -> Ok(Nil)
      }
    }
  }
}

fn files_cardinality_detail(
  capability: String,
  max_files: Int,
  received_files: Int,
) -> String {
  "invalid files cardinality: capability="
  <> capability
  <> " max_files="
  <> int.to_string(max_files)
  <> " received_files="
  <> int.to_string(received_files)
}

fn encode_agent_info(
  req: request.Request(mist.Connection),
  info: types_agent.AgentInfoView,
) -> json.Json {
  let capabilities = encode_capabilities(info.interface)

  json.object([
    #("profile_id", json.string(types_core.profile_id_to_string(info.meta.id))),
    #(
      "instance_id",
      json.string(types_core.instance_id_to_string(info.status.instance_id)),
    ),
    #("a2a_base_url", json.string(a2a_base_url(req, info.status.instance_id))),
    #("description", json.string(info.meta.description)),
    #("capabilities", capabilities),
  ])
}

fn encode_capabilities(interface: types_profile.Interface) -> json.Json {
  case interface {
    types_profile.RunnerInterface(caps) ->
      json.object(
        dict.to_list(caps)
        |> list.map(fn(pair) {
          let #(name, cap) = pair
          capability_view(
            name,
            cap.streaming,
            cap.response_mode,
            cap.input_schema,
            cap.description,
            cap.limits,
            cap.files,
          )
        }),
      )

    types_profile.HttpInterface(_, _, _, caps) ->
      json.object(
        dict.to_list(caps)
        |> list.map(fn(pair) {
          let #(name, cap) = pair
          capability_view(
            name,
            cap.streaming,
            cap.response_mode,
            cap.input_schema,
            cap.description,
            cap.limits,
            cap.files,
          )
        }),
      )
  }
}

fn capability_view(
  name: String,
  streaming: Bool,
  response_mode: types_profile.ResponseMode,
  input_schema: Option(types_profile.InputSchema),
  description: Option(String),
  limits: Option(types_profile.CapabilityLimits),
  files: Option(types_profile.FilesSemantics),
) -> #(String, json.Json) {
  #(
    name,
    json.object([
      #("streaming", json.bool(streaming)),
      #("response_mode", json.string(encode_response_mode(response_mode))),
      #("input_schema", encode_input_schema(input_schema)),
      #("description", encode_optional_string(description)),
      #("limits", encode_capability_limits(limits)),
      #("files", encode_files_semantics(files)),
    ]),
  )
}

fn encode_response_mode(mode: types_profile.ResponseMode) -> String {
  types_profile.response_mode_to_string(mode)
}

fn encode_capability_limits(
  limits: Option(types_profile.CapabilityLimits),
) -> json.Json {
  case limits {
    None -> json.null()
    Some(types_profile.CapabilityLimits(call_timeout_ms: call_timeout_ms)) ->
      json.object([
        #("timeout_ms", case call_timeout_ms {
          Some(ms) -> json.int(ms)
          None -> json.null()
        }),
      ])
  }
}

fn encode_files_semantics(
  files: Option(types_profile.FilesSemantics),
) -> json.Json {
  case files {
    None -> json.null()
    Some(types_profile.FilesSemantics(
      accepts: accepts,
      max_files: max_files,
      ingest_effect: ingest_effect,
    )) ->
      json.object([
        #("accepts", json.bool(accepts)),
        #("max_files", json.int(max_files)),
        #("ingest_effect", case ingest_effect {
          Some(effect) ->
            json.string(types_profile.ingest_effect_to_string(effect))
          None -> json.null()
        }),
      ])
  }
}

fn encode_input_schema(schema: Option(types_profile.InputSchema)) -> json.Json {
  case schema {
    None -> json.null()
    Some(types_profile.SchemaChat) -> json.string("std:chat")
    Some(types_profile.SchemaFiles) -> json.string("std:files")
    Some(types_profile.SchemaChatExtended(extra_fields)) ->
      json.object([
        #("base", json.string("std:chat")),
        #(
          "extra_fields",
          json.object(
            dict.to_list(extra_fields)
            |> list.map(fn(pair) {
              let #(k, def) = pair
              #(
                k,
                json.object([
                  #("type", json.string(extra_field_type(def.type_))),
                ]),
              )
            }),
          ),
        ),
      ])
  }
}

fn extra_field_type(t: types_profile.ExtraFieldType) -> String {
  case t {
    types_profile.FieldString -> "string"
    types_profile.FieldBoolean -> "boolean"
    types_profile.FieldNumber -> "number"
    types_profile.FieldInteger -> "integer"
  }
}

fn encode_optional_string(s: Option(String)) -> json.Json {
  case s {
    Some(v) -> json.string(v)
    None -> json.null()
  }
}

fn encode_interaction_result(
  result: types_output.InteractionResult,
) -> json.Json {
  let data =
    json.object([
      #("content", case result.data.content {
        Some(c) -> json.string(c)
        None -> json.null()
      }),
      #("metadata", json.object(dict.to_list(result.data.metadata))),
    ])

  json.object([
    #("status", json.string("success")),
    #("data", data),
    #(
      "artifacts",
      json.array(result.artifacts, fn(a) {
        json.object([
          #("id", json.string(types_core.artifact_id_to_string(a.id))),
          #("name", json.string(a.name)),
          #("url", case a.url {
            Some(u) -> json.string(u)
            None -> json.null()
          }),
          #("mime", json.string(a.mime)),
        ])
      }),
    ),
    #("trace_id", json.string(types_core.trace_id_to_string(result.trace_id))),
  ])
}

fn interaction_error_to_response(
  req: request.Request(mist.Connection),
  trace_id: types_core.TraceId,
  err: types_output.InteractionError,
) -> response.Response(mist.ResponseData) {
  case err.kind, err.message {
    types_enums.InfraError, "timeout" ->
      problem.from_call_error(safe_call.TimedOut, trace_id, req.path)
    types_enums.InfraError, "disconnected" ->
      problem.from_call_error(safe_call.Disconnected, trace_id, req.path)
    types_enums.AgentError, "interact_while_busy" ->
      problem.from_error_kind(
        types_enums.AgentError,
        trace_id,
        req.path,
        "Agent is busy",
      )
    _, _ -> problem.from_error_kind(err.kind, trace_id, req.path, err.message)
  }
}

fn parse_instance_id_or_400(
  raw: String,
  trace_id: types_core.TraceId,
  path: String,
) -> Result(types_core.InstanceId, response.Response(mist.ResponseData)) {
  case types_core.instance_id(raw) {
    Ok(id) -> Ok(id)
    Error(err) ->
      Error(problem.from_error_kind(
        types_enums.BadRequest,
        trace_id,
        path,
        "invalid instance_id: " <> types_core.instance_id_error_to_string(err),
      ))
  }
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

fn status_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(status_timeout_ms: ms, ..) = timeouts
  ms
}

fn registry_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(registry_timeout_ms: ms, ..) = timeouts
  ms
}

fn task_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(call_timeout_ms: ms, ..) = timeouts
  ms
}

fn max_request_body_bytes(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(limits: limits, ..) = cfg
  let types_config.SaarLimits(max_request_body_bytes: bytes, ..) = limits
  bytes
}

fn sse_keep_alive_interval_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(stream: stream, ..) = cfg
  let types_config.StreamConfig(sse_keep_alive_interval_ms: ms, ..) = stream
  ms
}

fn task_store_error_to_response(
  trace_id: types_core.TraceId,
  path: String,
  err: types_task.TaskStoreError,
) -> response.Response(mist.ResponseData) {
  case err {
    types_task.TaskNotFound -> problem.not_found(trace_id, path)
    types_task.TaskLimitReached(_) ->
      problem.from_error_kind(
        types_enums.InfraError,
        trace_id,
        path,
        "max tasks reached",
      )
    types_task.TaskResultTooLarge(_, _) ->
      problem.from_error_kind(
        types_enums.InfraError,
        trace_id,
        path,
        "task result too large",
      )
  }
}

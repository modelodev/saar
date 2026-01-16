//// `/instances/:instance_id/a2a` HTTP API.
////
//// Mission: expose A2A-compatible endpoints per instance.
////
//// Responsibilities:
//// - Implement `GET /instances/:instance_id/.well-known/agent-card.json`.
//// - Implement `POST /instances/:instance_id/a2a/message:send`.
//// - Implement `POST /instances/:instance_id/a2a/message:stream`.
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
import saar/gateway/lookup_http
import saar/gateway/problem
import saar/gateway/request_url
import saar/otp/safe_call
import saar/streams/sink
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/profile as types_profile
import youid/uuid

pub type Deps {
  Deps(registry: process.Subject(messages.RegistryMsg))
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
          let Deps(registry: registry) = deps

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
          let Deps(registry: registry) = deps

          lookup_http.with_agent_ref(
            registry,
            registry_timeout_ms(cfg),
            trace_id,
            req.path,
            instance_id,
            fn(agent_ref) {
              message_send_with_agent(req, cfg, trace_id, agent_ref)
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
            req0: req0,
            timeout_ms: timeout_ms,
            ..,
          ) = prepared

          case agent.interact(agent_ref, req0, sink.NonStreaming, timeout_ms) {
            Ok(result) ->
              json_response(200, a2a.message_send_response(result, context_id))

            Error(err) ->
              problem.from_error_kind_a2a(err.kind, trace_id, err.message)
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
          let Deps(registry: registry) = deps

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

fn sse_keep_alive_interval_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(stream: stream, ..) = cfg
  let types_config.StreamConfig(sse_keep_alive_interval_ms: ms, ..) = stream
  ms
}

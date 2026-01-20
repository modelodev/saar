////
//// Mission: expose deferred task endpoints under `/tasks`.
////
//// Responsibilities:
//// - Implement `GET /tasks/:task_id` and `DELETE /tasks/:task_id`.
//// - Implement `GET /tasks/:task_id/subscribe` (SSE snapshot + updates).
//// - Encode TaskStore records into client-facing JSON.
////
//// Non-responsibilities:
//// - Executing interactions (handled by `/agents/.../interact`).
//// - Persisting task state beyond memory.
////
//// Relationships:
//// - Uses `saar/core/task_store` for task persistence.
//// - Uses `saar/core/agent` for best-effort cancellation.
//// - Routes are wired from `saar/gateway/http_server`.

import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option
import gleam/yielder
import mist
import saar/core/agent
import saar/core/messages
import saar/core/task_store
import saar/core/task_store_protocol
import saar/ffi
import saar/gateway/lookup
import saar/gateway/problem
import saar/otp/safe_call
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/output as types_output
import saar/types/task as types_task

pub type Deps {
  Deps(
    registry: process.Subject(messages.RegistryMsg),
    task_store: process.Subject(task_store_protocol.TaskStoreMsg),
  )
}

/// Routes task endpoints under `/tasks`.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["tasks", task_id] -> handle_task_item(req, cfg, deps, trace_id, task_id)
    ["tasks", task_id, "subscribe"] ->
      handle_task_subscribe(req, cfg, deps, trace_id, task_id)
    _ -> problem.not_found(trace_id, req.path)
  }
}

fn handle_task_item(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id_raw: String,
) -> response.Response(mist.ResponseData) {
  let task_id = types_core.trace_id(task_id_raw)

  case req.method {
    http.Get -> get_task_response(req, cfg, deps, trace_id, task_id)
    http.Delete -> delete_task_response(req, cfg, deps, trace_id, task_id)
    _ -> empty_response(405)
  }
}

fn handle_task_subscribe(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get ->
      get_task_for_subscribe(
        req,
        cfg,
        deps,
        trace_id,
        types_core.trace_id(task_id_raw),
      )
    _ -> empty_response(405)
  }
}

fn get_task_response(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps

  case task_store.get_task(store, task_timeout_ms(cfg), task_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)
    Ok(option.None) -> problem.not_found(trace_id, req.path)
    Ok(option.Some(record)) -> json_response(200, encode_task_record(record))
  }
}

fn delete_task_response(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps

  case task_store.get_task(store, task_timeout_ms(cfg), task_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)
    Ok(option.None) -> problem.not_found(trace_id, req.path)
    Ok(option.Some(record)) ->
      delete_task_record(req, cfg, deps, trace_id, task_id, record)
  }
}

fn delete_task_record(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
  record: types_task.TaskRecord,
) -> response.Response(mist.ResponseData) {
  let types_task.TaskRecord(status: status, ..) = record

  case status {
    types_task.TaskRunning ->
      cancel_running_task(req, cfg, deps, trace_id, record)
    _ -> delete_terminal_task(req, cfg, deps, trace_id, task_id)
  }
}

fn cancel_running_task(
  req: request.Request(mist.Connection),
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
    Ok(updated) -> json_response(200, encode_task_record(updated))
    Error(safe_call.CallFailed(call_err)) ->
      problem.from_call_error(call_err, trace_id, req.path)
    Error(safe_call.ActorError(err)) ->
      task_store_error_response(trace_id, req.path, err)
  }
}

fn delete_terminal_task(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps

  case task_store.delete_task(store, task_timeout_ms(cfg), task_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)
    Ok(False) -> problem.not_found(trace_id, req.path)
    Ok(True) -> empty_response(204)
  }
}

fn get_task_for_subscribe(
  req: request.Request(mist.Connection),
  cfg: types_config.SaarConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  task_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let Deps(task_store: store, ..) = deps

  case task_store.get_task(store, task_timeout_ms(cfg), task_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)
    Ok(option.None) -> problem.not_found(trace_id, req.path)
    Ok(option.Some(record)) -> subscribe_task_response(cfg, deps, record)
  }
}

type SubscribeState {
  SubscribeState(
    sent_initial: Bool,
    last_status: types_task.TaskStatus,
    closed: Bool,
  )
}

fn subscribe_task_response(
  cfg: types_config.SaarConfig,
  deps: Deps,
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
        next_subscription_step(cfg, deps, record, task_id, state, keep_alive_ms)
      },
    )

  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> response.set_body(mist.Chunked(stream))
}

fn next_subscription_step(
  cfg: types_config.SaarConfig,
  deps: Deps,
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
        False -> poll_task_for_updates(cfg, deps, task_id, state, keep_alive_ms)
      }
  }
}

fn poll_task_for_updates(
  cfg: types_config.SaarConfig,
  deps: Deps,
  task_id: types_core.TraceId,
  state: SubscribeState,
  keep_alive_ms: Int,
) -> yielder.Step(bytes_tree.BytesTree, SubscribeState) {
  process.sleep(keep_alive_ms)

  case fetch_task_record(cfg, deps, task_id) {
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
  let payload = encode_task_record(record) |> json.to_string
  bytes_tree.from_string("data: " <> payload <> "\n\n")
}

fn fetch_task_record(
  cfg: types_config.SaarConfig,
  deps: Deps,
  task_id: types_core.TraceId,
) -> option.Option(types_task.TaskRecord) {
  let Deps(task_store: store, ..) = deps
  let timeout_ms = task_timeout_ms(cfg)

  case task_store.get_task(store, timeout_ms, task_id) {
    Ok(option.Some(record)) -> option.Some(record)
    _ -> option.None
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

pub fn encode_task_record(record: types_task.TaskRecord) -> json.Json {
  let types_task.TaskRecord(
    id: id,
    instance_id: instance_id,
    context_id: context_id,
    status: status,
    ..,
  ) = record

  json.object([
    #("task_id", json.string(types_core.trace_id_to_string(id))),
    #("instance_id", json.string(types_core.instance_id_to_string(instance_id))),
    #("context_id", case context_id {
      option.Some(value) -> json.string(value)
      option.None -> json.null()
    }),
    #("state", json.string(types_task.task_status_to_string(status))),
    #("result", encode_task_result(status)),
    #("error", encode_task_error(status)),
  ])
}

fn encode_task_result(status: types_task.TaskStatus) -> json.Json {
  case status {
    types_task.TaskCompleted(result) -> encode_interaction_result(result)
    _ -> json.null()
  }
}

fn encode_task_error(status: types_task.TaskStatus) -> json.Json {
  case status {
    types_task.TaskFailed(err) -> encode_interaction_error(err)
    types_task.TaskCancelled(err) -> encode_interaction_error(err)
    _ -> json.null()
  }
}

fn encode_interaction_result(
  result: types_output.InteractionResult,
) -> json.Json {
  let data =
    json.object([
      #("content", case result.data.content {
        option.Some(c) -> json.string(c)
        option.None -> json.null()
      }),
      #("metadata", json.object(dict.to_list(result.data.metadata))),
    ])

  json.object([
    #("status", json.string("success")),
    #("data", data),
    #(
      "artifacts",
      json.array(result.artifacts, fn(artifact) {
        json.object([
          #("id", json.string(types_core.artifact_id_to_string(artifact.id))),
          #("name", json.string(artifact.name)),
          #("url", case artifact.url {
            option.Some(url) -> json.string(url)
            option.None -> json.null()
          }),
          #("mime", json.string(artifact.mime)),
        ])
      }),
    ),
    #("trace_id", json.string(types_core.trace_id_to_string(result.trace_id))),
  ])
}

fn encode_interaction_error(err: types_output.InteractionError) -> json.Json {
  json.object([
    #("kind", json.string(types_enums.error_kind_to_string(err.kind))),
    #("message", json.string(err.message)),
    #("trace_id", json.string(types_core.trace_id_to_string(err.trace_id))),
  ])
}

fn task_store_error_response(
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

fn task_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(call_timeout_ms: call_timeout_ms, ..) = timeouts
  call_timeout_ms
}

fn registry_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(registry_timeout_ms: ms, ..) = timeouts
  ms
}

fn sse_keep_alive_interval_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(stream: stream, ..) = cfg
  let types_config.StreamConfig(sse_keep_alive_interval_ms: ms, ..) = stream
  ms
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

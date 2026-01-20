//// TaskStore actor for deferred interactions.
////
//// Mission: keep deferred task state in memory with bounded retention and
//// size limits.
////
//// Responsibilities:
//// - Store task records by trace id.
//// - Enforce `max_tasks` and `max_task_result_bytes` limits.
//// - Support explicit deletion and retention-based garbage collection.
////
//// Non-responsibilities:
//// - Persisting tasks across restarts.
//// - Mapping task records into HTTP/A2A responses.
////
//// Relationships:
//// - Uses `saar/core/task_store_protocol` for its message protocol.
//// - Uses `saar/types/task` for task records and errors.

import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import saar/core/task_store_protocol
import saar/otp/safe_call
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/output as types_output
import saar/types/task as types_task

type State {
  State(
    tasks: dict.Dict(types_core.TraceId, types_task.TaskRecord),
    retention_ms: Int,
    max_tasks: Int,
    max_result_bytes: Int,
  )
}

/// Starts an unnamed TaskStore actor.
pub fn start_unnamed(
  config: types_config.SaarConfig,
) -> actor.StartResult(process.Subject(task_store_protocol.TaskStoreMsg)) {
  actor.new(initial_state(config))
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Starts a named TaskStore actor.
pub fn start(
  name: process.Name(task_store_protocol.TaskStoreMsg),
  config: types_config.SaarConfig,
) -> actor.StartResult(process.Subject(task_store_protocol.TaskStoreMsg)) {
  actor.new(initial_state(config))
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Creates a task with the provided trace id.
pub fn create_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
  instance_id: types_core.InstanceId,
  capability: String,
  now_ms: Int,
) -> Result(
  types_task.TaskRecord,
  safe_call.ApiCallError(types_task.TaskStoreError),
) {
  safe_call.call_unwrap_result(store, timeout_ms, fn(reply_to) {
    task_store_protocol.CreateTask(
      id,
      instance_id,
      capability,
      now_ms,
      reply_to,
    )
  })
}

/// Returns the task record for a trace id, if present.
pub fn get_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
) -> Result(option.Option(types_task.TaskRecord), safe_call.CallError) {
  safe_call.call(store, timeout_ms, fn(reply_to) {
    task_store_protocol.GetTask(id, reply_to)
  })
}

/// Stores a completed result for a task.
pub fn complete_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
  result: types_output.InteractionResult,
  now_ms: Int,
) -> Result(
  types_task.TaskRecord,
  safe_call.ApiCallError(types_task.TaskStoreError),
) {
  safe_call.call_unwrap_result(store, timeout_ms, fn(reply_to) {
    task_store_protocol.CompleteTask(id, result, now_ms, reply_to)
  })
}

/// Stores a failure for a task.
pub fn fail_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
  error: types_output.InteractionError,
  now_ms: Int,
) -> Result(
  types_task.TaskRecord,
  safe_call.ApiCallError(types_task.TaskStoreError),
) {
  safe_call.call_unwrap_result(store, timeout_ms, fn(reply_to) {
    task_store_protocol.FailTask(id, error, now_ms, reply_to)
  })
}

/// Stores a cancellation for a task.
pub fn cancel_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
  error: types_output.InteractionError,
  now_ms: Int,
) -> Result(
  types_task.TaskRecord,
  safe_call.ApiCallError(types_task.TaskStoreError),
) {
  safe_call.call_unwrap_result(store, timeout_ms, fn(reply_to) {
    task_store_protocol.CancelTask(id, error, now_ms, reply_to)
  })
}

/// Deletes a task record explicitly.
pub fn delete_task(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  id: types_core.TraceId,
) -> Result(Bool, safe_call.CallError) {
  safe_call.call(store, timeout_ms, fn(reply_to) {
    task_store_protocol.DeleteTask(id, reply_to)
  })
}

/// Runs retention-based garbage collection.
pub fn gc(
  store: process.Subject(task_store_protocol.TaskStoreMsg),
  timeout_ms: Int,
  now_ms: Int,
) -> Result(Int, safe_call.CallError) {
  safe_call.call(store, timeout_ms, fn(reply_to) {
    task_store_protocol.Gc(now_ms, reply_to)
  })
}

fn initial_state(config: types_config.SaarConfig) -> State {
  let types_config.SaarConfig(limits: limits, ..) = config
  let types_config.SaarLimits(
    task_retention_ms: retention_ms,
    max_tasks: max_tasks,
    max_task_result_bytes: max_result_bytes,
    ..,
  ) = limits

  State(
    tasks: dict.new(),
    retention_ms: retention_ms,
    max_tasks: max_tasks,
    max_result_bytes: max_result_bytes,
  )
}

fn handle_message(
  state: State,
  msg: task_store_protocol.TaskStoreMsg,
) -> actor.Next(State, task_store_protocol.TaskStoreMsg) {
  case msg {
    task_store_protocol.CreateTask(
      id,
      instance_id,
      capability,
      now_ms,
      reply_to,
    ) -> {
      let #(next, result) =
        create_task_state(state, id, instance_id, capability, now_ms)
      process.send(reply_to, result)
      actor.continue(next)
    }

    task_store_protocol.GetTask(id, reply_to) -> {
      let State(tasks: tasks, ..) = state
      process.send(reply_to, dict.get(tasks, id) |> option.from_result)
      actor.continue(state)
    }

    task_store_protocol.CompleteTask(id, result, now_ms, reply_to) -> {
      let #(next, out) = complete_task_state(state, id, result, now_ms)
      process.send(reply_to, out)
      actor.continue(next)
    }

    task_store_protocol.FailTask(id, error, now_ms, reply_to) -> {
      let #(next, out) =
        update_task_state(state, id, now_ms, types_task.TaskFailed(error))
      process.send(reply_to, out)
      actor.continue(next)
    }

    task_store_protocol.CancelTask(id, error, now_ms, reply_to) -> {
      let #(next, out) =
        update_task_state(state, id, now_ms, types_task.TaskCancelled(error))
      process.send(reply_to, out)
      actor.continue(next)
    }

    task_store_protocol.DeleteTask(id, reply_to) -> {
      let #(next, deleted) = delete_task_state(state, id)
      process.send(reply_to, deleted)
      actor.continue(next)
    }

    task_store_protocol.Gc(now_ms, reply_to) -> {
      let #(next, removed) = gc_state(state, now_ms)
      process.send(reply_to, removed)
      actor.continue(next)
    }
  }
}

fn create_task_state(
  state: State,
  id: types_core.TraceId,
  instance_id: types_core.InstanceId,
  capability: String,
  now_ms: Int,
) -> #(State, Result(types_task.TaskRecord, types_task.TaskStoreError)) {
  let State(tasks: tasks, max_tasks: max_tasks, ..) = state

  case dict.get(tasks, id) {
    Ok(existing) -> #(state, Ok(existing))
    Error(_) ->
      case dict.size(tasks) >= max_tasks {
        True -> #(
          state,
          Error(types_task.TaskLimitReached(max_tasks: max_tasks)),
        )
        False -> {
          let record =
            types_task.TaskRecord(
              id: id,
              instance_id: instance_id,
              capability: capability,
              status: types_task.TaskRunning,
              created_at_ms: now_ms,
              updated_at_ms: now_ms,
            )
          let next_tasks = dict.insert(tasks, id, record)
          #(State(..state, tasks: next_tasks), Ok(record))
        }
      }
  }
}

fn complete_task_state(
  state: State,
  id: types_core.TraceId,
  result: types_output.InteractionResult,
  now_ms: Int,
) -> #(State, Result(types_task.TaskRecord, types_task.TaskStoreError)) {
  let State(max_result_bytes: max_bytes, ..) = state
  let actual_bytes = interaction_result_bytes(result)

  case actual_bytes > max_bytes {
    True -> #(
      state,
      Error(types_task.TaskResultTooLarge(actual_bytes, max_bytes)),
    )
    False ->
      update_task_state(state, id, now_ms, types_task.TaskCompleted(result))
  }
}

fn update_task_state(
  state: State,
  id: types_core.TraceId,
  now_ms: Int,
  next_status: types_task.TaskStatus,
) -> #(State, Result(types_task.TaskRecord, types_task.TaskStoreError)) {
  let State(tasks: tasks, ..) = state

  case dict.get(tasks, id) {
    Error(_) -> #(state, Error(types_task.TaskNotFound))

    Ok(record) ->
      case record.status {
        types_task.TaskRunning -> {
          let updated =
            types_task.TaskRecord(
              ..record,
              status: next_status,
              updated_at_ms: now_ms,
            )
          let next_tasks = dict.insert(tasks, id, updated)
          #(State(..state, tasks: next_tasks), Ok(updated))
        }

        _ -> #(state, Ok(record))
      }
  }
}

fn delete_task_state(state: State, id: types_core.TraceId) -> #(State, Bool) {
  let State(tasks: tasks, ..) = state
  case dict.has_key(tasks, id) {
    True -> #(State(..state, tasks: dict.delete(tasks, id)), True)
    False -> #(state, False)
  }
}

fn gc_state(state: State, now_ms: Int) -> #(State, Int) {
  let State(tasks: tasks, retention_ms: retention_ms, ..) = state

  tasks
  |> dict.to_list
  |> list.fold(#(dict.new(), 0), fn(acc, entry) {
    let #(next_tasks, removed) = acc
    let #(task_id, record) = entry
    let types_task.TaskRecord(status: status, updated_at_ms: updated_at, ..) =
      record

    case
      types_task.task_status_is_terminal(status)
      && now_ms - updated_at >= retention_ms
    {
      True -> #(next_tasks, removed + 1)
      False -> #(dict.insert(next_tasks, task_id, record), removed)
    }
  })
  |> fn(result) { #(State(..state, tasks: result.0), result.1) }
}

fn interaction_result_bytes(result: types_output.InteractionResult) -> Int {
  interaction_result_json(result)
  |> json.to_string
  |> string.byte_size
}

fn interaction_result_json(result: types_output.InteractionResult) -> json.Json {
  let data =
    json.object([
      #("content", case result.data.content {
        option.Some(value) -> json.string(value)
        option.None -> json.null()
      }),
      #("metadata", json.object(dict.to_list(result.data.metadata))),
    ])

  json.object([
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

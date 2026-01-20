//// TaskStore message protocol.
////
//// Mission: define the OTP message types exchanged with the TaskStore actor.
////
//// Responsibilities:
//// - Provide the SSOT for TaskStore request/reply messages.
//// - Keep the protocol separate from the actor implementation.
////
//// Non-responsibilities:
//// - Implementing the TaskStore behavior.
//// - Encoding tasks for HTTP clients.
////
//// Relationships:
//// - Used by `saar/core/task_store`.
//// - Used by boundary callers via `saar/otp/safe_call`.

import gleam/erlang/process.{type Subject}
import gleam/option
import saar/types/core as types_core
import saar/types/output as types_output
import saar/types/task as types_task

/// Message protocol for the TaskStore actor.
pub type TaskStoreMsg {
  CreateTask(
    id: types_core.TraceId,
    instance_id: types_core.InstanceId,
    capability: String,
    context_id: option.Option(String),
    now_ms: Int,
    reply_to: Subject(
      Result(types_task.TaskCreateResult, types_task.TaskStoreError),
    ),
  )
  GetTask(
    id: types_core.TraceId,
    reply_to: Subject(option.Option(types_task.TaskRecord)),
  )
  CompleteTask(
    id: types_core.TraceId,
    result: types_output.InteractionResult,
    now_ms: Int,
    reply_to: Subject(Result(types_task.TaskRecord, types_task.TaskStoreError)),
  )
  FailTask(
    id: types_core.TraceId,
    error: types_output.InteractionError,
    now_ms: Int,
    reply_to: Subject(Result(types_task.TaskRecord, types_task.TaskStoreError)),
  )
  CancelTask(
    id: types_core.TraceId,
    error: types_output.InteractionError,
    now_ms: Int,
    reply_to: Subject(Result(types_task.TaskRecord, types_task.TaskStoreError)),
  )
  DeleteTask(id: types_core.TraceId, reply_to: Subject(Bool))
  Gc(now_ms: Int, reply_to: Subject(Int))
}

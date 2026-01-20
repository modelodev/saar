//// Task definitions for deferred interactions.
////
//// Mission: represent the lifecycle of deferred tasks and their stored results.
////
//// Responsibilities:
//// - Provide the task status ADT for deferred responses.
//// - Provide the stored task record with timestamps.
//// - Offer small helpers for task status and store errors.
////
//// Non-responsibilities:
//// - Persisting task data across restarts.
//// - HTTP encoding/decoding of task payloads.
////
//// Relationships:
//// - Used by `saar/core/task_store`.
//// - Consumed by gateway APIs for deferred task views.

import gleam/option.{type Option}
import saar/types/core as types_core
import saar/types/output as types_output

/// State of a deferred task stored in memory.
pub type TaskStatus {
  TaskRunning
  TaskCompleted(result: types_output.InteractionResult)
  TaskFailed(error: types_output.InteractionError)
  TaskCancelled(error: types_output.InteractionError)
}

/// Stored task record with lifecycle timestamps and optional context id.
pub type TaskRecord {
  TaskRecord(
    id: types_core.TraceId,
    instance_id: types_core.InstanceId,
    capability: String,
    context_id: Option(String),
    status: TaskStatus,
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}

/// Outcome of creating a task in the TaskStore.
pub type TaskCreateResult {
  TaskCreated(record: TaskRecord)
  TaskExisting(record: TaskRecord)
}

/// Errors returned by the TaskStore actor.
pub type TaskStoreError {
  TaskNotFound
  TaskLimitReached(max_tasks: Int)
  TaskResultTooLarge(actual_bytes: Int, max_bytes: Int)
}

/// Returns True when the task status is terminal.
pub fn task_status_is_terminal(status: TaskStatus) -> Bool {
  case status {
    TaskRunning -> False
    TaskCompleted(_) -> True
    TaskFailed(_) -> True
    TaskCancelled(_) -> True
  }
}

/// Returns a stable string representation for task status.
pub fn task_status_to_string(status: TaskStatus) -> String {
  case status {
    TaskRunning -> "running"
    TaskCompleted(_) -> "completed"
    TaskFailed(_) -> "failed"
    TaskCancelled(_) -> "cancelled"
  }
}

/// Returns the task record from a create result.
pub fn task_create_record(result: TaskCreateResult) -> TaskRecord {
  case result {
    TaskCreated(record) -> record
    TaskExisting(record) -> record
  }
}

/// Returns a stable code for TaskStore errors.
pub fn task_store_error_to_string(err: TaskStoreError) -> String {
  case err {
    TaskNotFound -> "not_found"
    TaskLimitReached(_) -> "max_tasks_reached"
    TaskResultTooLarge(_, _) -> "result_too_large"
  }
}

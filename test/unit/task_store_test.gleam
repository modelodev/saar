import gleam/dict
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import saar/core/task_store
import saar/otp/safe_call
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/output as types_output
import saar/types/task as types_task

pub fn main() {
  gleeunit.main()
}

pub fn store_roundtrip_get() {
  let cfg =
    test_config(retention_ms: 1000, max_tasks: 10, max_result_bytes: 1000)
  let assert Ok(actor.Started(data: store, ..)) = task_store.start_unnamed(cfg)
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let trace_id = types_core.trace_id("trace-1")

  task_store.create_task(
    store,
    1000,
    trace_id,
    instance_id,
    "chat",
    option.None,
    10,
  )
  |> should.be_ok

  let result = sample_result(trace_id, "ok")
  task_store.complete_task(store, 1000, trace_id, result, 20)
  |> should.be_ok

  let assert Ok(option.Some(task)) = task_store.get_task(store, 1000, trace_id)

  case task.status {
    types_task.TaskCompleted(done) ->
      done.trace_id
      |> types_core.trace_id_to_string
      |> should.equal("trace-1")
    _ -> should.fail()
  }
}

pub fn gc_removes_old_terminal_tasks() {
  let cfg = test_config(retention_ms: 50, max_tasks: 10, max_result_bytes: 1000)
  let assert Ok(actor.Started(data: store, ..)) = task_store.start_unnamed(cfg)
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let trace_id = types_core.trace_id("trace-gc")

  task_store.create_task(
    store,
    1000,
    trace_id,
    instance_id,
    "chat",
    option.None,
    0,
  )
  |> should.be_ok

  let result = sample_result(trace_id, "ok")
  task_store.complete_task(store, 1000, trace_id, result, 10)
  |> should.be_ok

  task_store.gc(store, 1000, 200)
  |> should.be_ok

  task_store.get_task(store, 1000, trace_id)
  |> should.equal(Ok(option.None))
}

pub fn max_tasks_limit_enforced() {
  let cfg =
    test_config(retention_ms: 1000, max_tasks: 1, max_result_bytes: 1000)
  let assert Ok(actor.Started(data: store, ..)) = task_store.start_unnamed(cfg)
  let assert Ok(instance_id) = types_core.instance_id("inst-1")

  task_store.create_task(
    store,
    1000,
    types_core.trace_id("trace-1"),
    instance_id,
    "chat",
    option.None,
    0,
  )
  |> should.be_ok

  case
    task_store.create_task(
      store,
      1000,
      types_core.trace_id("trace-2"),
      instance_id,
      "chat",
      option.None,
      0,
    )
  {
    Error(safe_call.ActorError(types_task.TaskLimitReached(max_tasks: 1))) ->
      Nil
    _ -> should.fail()
  }
}

pub fn max_task_result_bytes_enforced() {
  let cfg = test_config(retention_ms: 1000, max_tasks: 10, max_result_bytes: 20)
  let assert Ok(actor.Started(data: store, ..)) = task_store.start_unnamed(cfg)
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let trace_id = types_core.trace_id("trace-big")

  task_store.create_task(
    store,
    1000,
    trace_id,
    instance_id,
    "chat",
    option.None,
    0,
  )
  |> should.be_ok

  let result = sample_result(trace_id, "this string is too long")

  case task_store.complete_task(store, 1000, trace_id, result, 10) {
    Error(safe_call.ActorError(types_task.TaskResultTooLarge(_, _))) -> Nil
    _ -> should.fail()
  }
}

fn test_config(
  retention_ms retention_ms: Int,
  max_tasks max_tasks: Int,
  max_result_bytes max_result_bytes: Int,
) -> types_config.SaarConfig {
  let cfg = types_config.default_saar_config()
  let types_config.SaarConfig(limits: limits, ..) = cfg

  let next_limits =
    types_config.SaarLimits(
      ..limits,
      task_retention_ms: retention_ms,
      max_tasks: max_tasks,
      max_task_result_bytes: max_result_bytes,
    )

  types_config.SaarConfig(..cfg, limits: next_limits)
}

fn sample_result(
  trace_id: types_core.TraceId,
  content: String,
) -> types_output.InteractionResult {
  types_output.InteractionResult(
    data: types_output.ResponseData(
      content: option.Some(content),
      metadata: dict.new(),
    ),
    artifacts: [],
    trace_id: trace_id,
  )
}

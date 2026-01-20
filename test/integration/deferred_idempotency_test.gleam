////
//// Mission: verify deferred interaction idempotency via trace_id.
////
//// Responsibilities:
//// - Ensure repeated deferred requests reuse the same task.
////
//// Non-responsibilities:
//// - Validating task subscription behavior.
//// - Validating A2A task semantics.
////
//// Relationships:
//// - Uses `test/tasks_helpers.gleam` for deferred interactions.

import gleam/dynamic/decode
import gleam/json
import gleeunit
import gleeunit/should
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn post_deferred_same_trace_id_returns_same_task() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-idempotent"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp1 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-idempotent",
      "hi",
    )

  resp1.status |> should.equal(202)
  let task_id1 = decode_task_id(resp1.body)

  let resp2 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-idempotent",
      "hi again",
    )

  resp2.status |> should.equal(202)
  let task_id2 = decode_task_id(resp2.body)

  task_id2 |> should.equal(task_id1)
}

fn decode_task_id(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

fn parse_dynamic(body: String) {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}

import gleam/dynamic/decode
import gleam/json
import gleeunit
import gleeunit/should
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn delete_task_running_cancels_task_state_cancelled() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-cancel"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-cancel",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let cancel_resp = tasks_helpers.delete_task(base_url, task_id)
  cancel_resp.status |> should.equal(200)
  decode_task_state(cancel_resp.body) |> should.equal("cancelled")

  let get_resp = tasks_helpers.get_task(base_url, task_id)
  decode_task_state(get_resp.body) |> should.equal("cancelled")
}

fn decode_task_id(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

fn decode_task_state(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

fn parse_dynamic(body: String) {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}
